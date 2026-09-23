-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110004_sorting_trolley_contents_intake_and_flow_queue
--
-- Purpose:
--   Build Sorting Trolley Intake as the authoritative bridge between:
--     physical trolley arrival -> received contents/empty -> wash queue
--     -> Production Flow.
--
-- Core safeguards:
--   * physical receipt date remains the real calendar date;
--   * operational Business Date follows the selected Sorting Shift;
--   * Customer + Scheduled Date + Product are explicit;
--   * off-schedule intake requires a reason;
--   * changing away from a trolley-history customer suggestion requires a reason;
--   * CONTENTS creates expected-to-wash evidence;
--   * EMPTY never fabricates a wash record;
--   * "Nothing to wash" is derived only when every known/planned trolley for that
--     schedule product is explicitly received EMPTY, no CONTENTS exists, and no
--     wash has been recorded;
--   * one recorded wash does not claim every received trolley is washed;
--   * Trolley Intake records the operational performer and authenticated recorder;
--   * old browser-write shortcuts are revoked.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Sorting-specific physical intake evidence
-- ---------------------------------------------------------------------

create table if not exists public.sorting_trolley_intakes (
  sorting_trolley_intake_id uuid primary key default gen_random_uuid(),
  stay_id uuid not null unique
    references public.trolley_customer_stays(stay_id) on delete restrict,
  trolley_id uuid not null
    references public.trolleys(trolley_id) on delete restrict,
  trolley_code_snapshot text not null,

  customer_id uuid not null
    references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text,
  customer_name_snapshot text not null,

  business_date date not null,
  physical_received_on date not null,
  shift_id uuid not null
    references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  arrived_at timestamptz not null default now(),

  contents_status text not null,
  product_scope text not null,
  scheduled_for_date date,
  schedule_relation text not null,

  confirmation_source text not null,
  suggestion_reason text,
  suggested_customer_id uuid
    references public.customers(customer_id) on delete restrict,
  customer_override_reason text,
  off_schedule_reason text,

  exception_type text,
  review_status text not null,

  operator_staff_id uuid not null
    references public.staff_members(staff_id) on delete restrict,
  recorded_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid
    references auth.users(id) on delete set null,

  notes text,
  created_at timestamptz not null default now(),

  constraint sorting_trolley_intakes_contents_check
    check (contents_status in ('CONTENTS','EMPTY')),
  constraint sorting_trolley_intakes_product_scope_check
    check (product_scope in ('CLOTHES','MOP','BOTH')),
  constraint sorting_trolley_intakes_relation_check
    check (schedule_relation in ('YESTERDAY','TODAY','TOMORROW','OFF_SCHEDULE')),
  constraint sorting_trolley_intakes_schedule_check
    check (
      (schedule_relation='OFF_SCHEDULE' and scheduled_for_date is null and off_schedule_reason is not null)
      or
      (schedule_relation<>'OFF_SCHEDULE' and scheduled_for_date is not null and off_schedule_reason is null)
    ),
  constraint sorting_trolley_intakes_review_check
    check (review_status in ('NOT_REQUIRED','PENDING','UNDER_REVIEW','RESOLVED'))
);

create index if not exists sorting_trolley_intakes_daily_idx
  on public.sorting_trolley_intakes(
    business_date, shift_id, contents_status, arrived_at, customer_id
  );

create index if not exists sorting_trolley_intakes_operator_idx
  on public.sorting_trolley_intakes(
    business_date, shift_id, operator_staff_id, arrived_at
  );

create index if not exists sorting_trolley_intakes_trolley_recent_idx
  on public.sorting_trolley_intakes(trolley_id, created_at desc);

alter table public.sorting_trolley_intakes enable row level security;
revoke all on table public.sorting_trolley_intakes
  from public, anon, authenticated;

create table if not exists public.sorting_trolley_intake_products (
  sorting_trolley_intake_product_id uuid primary key default gen_random_uuid(),
  sorting_trolley_intake_id uuid not null
    references public.sorting_trolley_intakes(sorting_trolley_intake_id) on delete restrict,

  product_code text not null,
  scheduled_for_date date,

  source_schedule_version_id uuid
    references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  source_schedule_day_id uuid
    references public.customer_schedule_days(schedule_day_id) on delete restrict,
  source_schedule_product_id uuid
    references public.customer_schedule_products(schedule_product_id) on delete restrict,

  production_order_snapshot integer,
  planned_trolley_quantity_snapshot integer,

  route_id_snapshot uuid
    references public.distribution_routes(route_id) on delete restrict,
  route_code_snapshot text,
  route_display_name_snapshot text,
  route_color_snapshot text,

  production_flow_item_id uuid not null
    references public.production_flow_items(production_flow_item_id) on delete restrict,

  created_at timestamptz not null default now(),

  constraint sorting_trolley_intake_products_product_check
    check (product_code in ('CLOTHES','MOP')),
  constraint sorting_trolley_intake_products_planned_trolley_check
    check (
      planned_trolley_quantity_snapshot is null
      or planned_trolley_quantity_snapshot >= 0
    ),
  constraint sorting_trolley_intake_products_schedule_check
    check (
      (scheduled_for_date is null
       and source_schedule_version_id is null
       and source_schedule_day_id is null
       and source_schedule_product_id is null)
      or
      (scheduled_for_date is not null
       and source_schedule_version_id is not null
       and source_schedule_day_id is not null
       and source_schedule_product_id is not null)
    ),
  constraint sorting_trolley_intake_products_unique
    unique (sorting_trolley_intake_id, product_code)
);

create index if not exists sorting_trolley_intake_products_schedule_idx
  on public.sorting_trolley_intake_products(
    source_schedule_product_id, scheduled_for_date, product_code
  );

create index if not exists sorting_trolley_intake_products_flow_idx
  on public.sorting_trolley_intake_products(production_flow_item_id);

alter table public.sorting_trolley_intake_products enable row level security;
revoke all on table public.sorting_trolley_intake_products
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Explicit physical-trolley content events
-- ---------------------------------------------------------------------

alter table public.trolley_events
  drop constraint if exists trolley_event_type_check;

alter table public.trolley_events
  add constraint trolley_event_type_check
  check (event_type = any(array[
    'TROLLEY_REGISTERED'::text,
    'ASSIGNED_IN_PRODUCTION'::text,
    'SENT_TO_CUSTOMER'::text,
    'DELIVERY_CONFIRMED'::text,
    'RECEIVED_FROM_CUSTOMER'::text,
    'RECEIVED_WITHOUT_OUTBOUND'::text,
    'ARRIVED_AT_SORTING'::text,
    'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND'::text,
    'CUSTOMER_MISMATCH'::text,
    'SORTING_CONTENTS_CONFIRMED'::text,
    'SORTING_EMPTY_CONFIRMED'::text,
    'EXCEPTION_REVIEW_STARTED'::text,
    'EXCEPTION_REOPENED'::text,
    'EXCEPTION_REVIEWED'::text,
    'RECORD_CORRECTED'::text,
    'MARKED_OUT_OF_SERVICE'::text,
    'RETURNED_TO_SERVICE'::text,
    'TROLLEY_RETIRED'::text
  ]));

-- ---------------------------------------------------------------------
-- 3. Deterministic operational state helper
-- ---------------------------------------------------------------------

create or replace function public.sorting_trolley_intake_state(
  p_planned_trolley_quantity integer,
  p_received_count integer,
  p_contents_count integer,
  p_empty_count integer,
  p_wash_count integer,
  p_review_count integer
)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_review_count,0) > 0 then 'REVIEW'
    when coalesce(p_wash_count,0) > 0 then 'WASHING_RECORDED'
    when coalesce(p_contents_count,0) > 0 then 'WAITING_WASH'
    when coalesce(p_planned_trolley_quantity,0) > 0
         and coalesce(p_received_count,0) >= p_planned_trolley_quantity
         and coalesce(p_empty_count,0) > 0
         and coalesce(p_contents_count,0) = 0
         and coalesce(p_wash_count,0) = 0
      then 'NOTHING_TO_WASH'
    when coalesce(p_received_count,0) > 0 then 'RECEIVED'
    else 'WAITING_RECEIPT'
  end;
$$;

create or replace function public.sorting_trolley_receipt_status(
  p_planned_trolley_quantity integer,
  p_received_count integer
)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_received_count,0)=0 then 'WAITING'
    when coalesce(p_planned_trolley_quantity,0)>0
         and p_received_count >= p_planned_trolley_quantity then 'COMPLETE'
    when coalesce(p_planned_trolley_quantity,0)>0 then 'PARTIAL'
    else 'RECEIVED'
  end;
$$;

revoke all on function public.sorting_trolley_intake_state(integer,integer,integer,integer,integer,integer)
  from public, anon, authenticated;
revoke all on function public.sorting_trolley_receipt_status(integer,integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Trolley Intake board/read model
--    Includes Yesterday only as a correction/date-selection option.
--    Main operational UI can focus Today + Tomorrow.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_trolley_intake_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_id uuid;
  v_board jsonb := '[]'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if v_shift_id is null then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  with board_days as (
    select v_business_date-1 as scheduled_for_date, 'YESTERDAY'::text as day_relation, -1 as day_offset
    union all
    select v_business_date, 'TODAY'::text, 0
    union all
    select v_business_date+1, 'TOMORROW'::text, 1
  ),
  scheduled as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      r.route_id,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      coalesce((
        select sum(req.quantity)::integer
        from public.customer_schedule_trolley_requirements req
        where req.schedule_day_id=sd.schedule_day_id
          and req.owner_schedule_product_id=sp.schedule_product_id
          and req.active=true
      ),0) as planned_trolley_quantity
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status='PUBLISHED'
     and csv.effective_from<=bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until>=bd.scheduled_for_date)
    join public.customers c
      on c.customer_id=csv.customer_id
     and c.active=true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id=csv.schedule_version_id
     and sd.active=true
     and sd.production_weekday=extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id=sd.schedule_day_id
     and sp.active=true
    join public.product_types pt
      on pt.product_type_id=sp.product_type_id
     and pt.active=true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES','MOP')
    left join public.distribution_routes r
      on r.route_id=sd.default_route_id
     and r.deleted_at is null
  ),
  enriched as (
    select
      s.*,
      coalesce(i.received_count,0) as received_count,
      coalesce(i.contents_count,0) as contents_count,
      coalesce(i.empty_count,0) as empty_count,
      coalesce(i.review_count,0) as review_count,
      i.first_received_at,
      i.last_received_at,
      coalesce(i.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(w.wash_count,0) as wash_count,
      w.last_wash_code,
      pfi.production_flow_item_id,
      coalesce(pfi.washed_kg_total,0) as flow_washed_kg,
      public.sorting_trolley_receipt_status(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0)
      ) as receipt_status,
      public.sorting_trolley_intake_state(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0),
        coalesce(i.contents_count,0),
        coalesce(i.empty_count,0),
        coalesce(w.wash_count,0),
        coalesce(i.review_count,0)
      ) as operational_state
    from scheduled s
    left join lateral (
      select
        count(*)::integer as received_count,
        count(*) filter (where sti.contents_status='CONTENTS')::integer as contents_count,
        count(*) filter (where sti.contents_status='EMPTY')::integer as empty_count,
        count(*) filter (where sti.review_status in ('PENDING','UNDER_REVIEW'))::integer as review_count,
        min(sti.arrived_at) as first_received_at,
        max(sti.arrived_at) as last_received_at,
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',sti.trolley_code_snapshot,
            'contents_status',sti.contents_status,
            'arrived_at',sti.arrived_at,
            'review_status',sti.review_status
          )
          order by sti.arrived_at
        ) as trolley_codes
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti
        on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      where stip.source_schedule_product_id=s.schedule_product_id
        and stip.scheduled_for_date=s.scheduled_for_date
        and sti.customer_id=s.customer_id
    ) i on true
    left join lateral (
      select
        count(*)::integer as wash_count,
        (
          select wr2.wash_code
          from public.sorting_wash_run_customers wrc2
          join public.sorting_wash_runs wr2 on wr2.wash_run_id=wrc2.wash_run_id
          where wr2.status='RECORDED'
            and wrc2.customer_id=s.customer_id
            and wrc2.source_schedule_product_id=s.schedule_product_id
            and wrc2.scheduled_for_date=s.scheduled_for_date
          order by wr2.started_at desc,wr2.created_at desc
          limit 1
        ) as last_wash_code
      from public.sorting_wash_run_customers wrc
      join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id
      where wr.status='RECORDED'
        and wrc.customer_id=s.customer_id
        and wrc.source_schedule_product_id=s.schedule_product_id
        and wrc.scheduled_for_date=s.scheduled_for_date
    ) w on true
    left join public.production_flow_items pfi
      on pfi.customer_id=s.customer_id
     and pfi.product_code=s.product_code
     and pfi.scheduled_for_date=s.scheduled_for_date
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',e.customer_id,
      'customer_code',e.customer_code,
      'customer_name',e.customer_name,
      'product_code',e.product_code,
      'scheduled_for_date',e.scheduled_for_date,
      'day_relation',e.day_relation,
      'day_offset',e.day_offset,
      'production_order',e.production_order,
      'production_instructions',e.production_instructions,
      'schedule_version_id',e.schedule_version_id,
      'schedule_day_id',e.schedule_day_id,
      'schedule_product_id',e.schedule_product_id,
      'route_id',e.route_id,
      'route_code',e.route_code,
      'route_display_name',e.route_display_name,
      'route_color',e.route_color,
      'planned_trolley_quantity',e.planned_trolley_quantity,
      'received_count',e.received_count,
      'contents_count',e.contents_count,
      'empty_count',e.empty_count,
      'review_count',e.review_count,
      'receipt_status',e.receipt_status,
      'operational_state',e.operational_state,
      'nothing_to_wash',e.operational_state='NOTHING_TO_WASH',
      'waiting_wash',e.operational_state='WAITING_WASH',
      'wash_count',e.wash_count,
      'last_wash_code',e.last_wash_code,
      'first_received_at',e.first_received_at,
      'last_received_at',e.last_received_at,
      'trolleys',e.trolley_codes,
      'production_flow_item_id',e.production_flow_item_id,
      'flow_washed_kg',e.flow_washed_kg
    )
    order by
      e.day_offset,
      case e.product_code when 'CLOTHES' then 1 else 2 end,
      e.production_order nulls last,
      lower(e.customer_name)
  ),'[]'::jsonb)
  into v_board
  from enriched e;

  with board as (
    select value as row
    from jsonb_array_elements(v_board)
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',row->>'customer_id',
      'customer_name',row->>'customer_name',
      'product_code',row->>'product_code',
      'scheduled_for_date',row->>'scheduled_for_date',
      'day_relation',row->>'day_relation',
      'route_code',row->>'route_code',
      'route_display_name',row->>'route_display_name',
      'route_color',row->>'route_color',
      'received_count',(row->>'received_count')::integer,
      'planned_trolley_quantity',(row->>'planned_trolley_quantity')::integer,
      'first_received_at',row->>'first_received_at',
      'production_flow_item_id',row->>'production_flow_item_id'
    )
    order by (row->>'first_received_at')::timestamptz,
             (row->>'production_order')::integer nulls last,
             lower(row->>'customer_name')
  ),'[]'::jsonb)
  into v_queue
  from board
  where row->>'operational_state'='WAITING_WASH'
    and row->>'day_relation' in ('TODAY','TOMORROW');

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'sorting_trolley_intake_id',q.sorting_trolley_intake_id,
      'trolley_code',q.trolley_code_snapshot,
      'customer_id',q.customer_id,
      'customer_name',q.customer_name_snapshot,
      'business_date',q.business_date,
      'physical_received_on',q.physical_received_on,
      'shift_code',q.shift_code_snapshot,
      'arrived_at',q.arrived_at,
      'contents_status',q.contents_status,
      'product_scope',q.product_scope,
      'scheduled_for_date',q.scheduled_for_date,
      'schedule_relation',q.schedule_relation,
      'review_status',q.review_status,
      'exception_type',q.exception_type,
      'operator_staff_id',q.operator_staff_id,
      'operator_name',operator.display_name,
      'notes',q.notes,
      'products',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'product_code',p.product_code,
            'production_flow_item_id',p.production_flow_item_id,
            'route_code',p.route_code_snapshot,
            'route_display_name',p.route_display_name_snapshot
          )
          order by p.product_code
        )
        from public.sorting_trolley_intake_products p
        where p.sorting_trolley_intake_id=q.sorting_trolley_intake_id
      ),'[]'::jsonb)
    )
    order by q.arrived_at desc
  ),'[]'::jsonb)
  into v_recent
  from (
    select *
    from public.sorting_trolley_intakes sti
    where sti.business_date=v_business_date
      and sti.shift_id=v_shift_id
    order by sti.arrived_at desc
    limit 30
  ) q
  left join public.staff_members operator
    on operator.staff_id=q.operator_staff_id;

  return jsonb_build_object(
    'business_date',v_business_date,
    'physical_date',current_date,
    'shift_code',upper(trim(p_shift_code)),
    'board',v_board,
    'waiting_queue',v_queue,
    'recent_intakes',v_recent,
    'summary',jsonb_build_object(
      'received_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
      ),
      'contents_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='CONTENTS'
      ),
      'empty_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='EMPTY'
      ),
      'waiting_wash',jsonb_array_length(v_queue)
    ),
    'source','PUBLISHED_SCHEDULE_PLUS_PHYSICAL_TROLLEY_INTAKE'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Preview V2: trolley lifecycle + operational Business Date
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_trolley_intake_preview_v2(
  p_shift_code text,
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
begin
  perform public.require_sorting_operational_access();

  v_base := public.get_sorting_trolley_intake_preview(p_trolley_code);

  return v_base || jsonb_build_object(
    'business_date',v_business_date,
    'physical_received_on',current_date,
    'shift_code',upper(trim(coalesce(p_shift_code,'')))
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Authoritative Trolley Intake write
-- ---------------------------------------------------------------------

create or replace function public.record_sorting_trolley_intake_v2(
  p_shift_code text,
  p_trolley_code text,
  p_operator_staff_id uuid,
  p_customer_id uuid,
  p_contents_status text,
  p_scheduled_for_date date,
  p_product_codes text[],
  p_customer_override_reason text default null,
  p_off_schedule_reason text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_code text := upper(trim(coalesce(p_trolley_code,'')));
  v_contents text := upper(trim(coalesce(p_contents_status,'')));
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_trolley public.trolleys%rowtype;
  v_customer public.customers%rowtype;
  v_suggestion record;
  v_confirmation_source text := 'MANUAL_SELECTION';
  v_customer_override_reason text := nullif(trim(coalesce(p_customer_override_reason,'')),'');
  v_off_schedule_reason text := nullif(trim(coalesce(p_off_schedule_reason,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_products text[];
  v_product text;
  v_product_scope text;
  v_relation text;
  v_receipt jsonb;
  v_stay_id uuid;
  v_intake public.sorting_trolley_intakes%rowtype;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_schedule_product_id uuid;
  v_production_order integer;
  v_planned_trolley_quantity integer;
  v_route_id uuid;
  v_route_code text;
  v_route_display_name text;
  v_route_color text;
  v_flow_id uuid;
  v_child_id uuid;
  v_actor_staff_id uuid := public.current_staff_id();
  v_attendance_inserted integer := 0;
  v_product_payload jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  if v_code='' then
    raise exception using errcode='22023', message='Trolley code is required.';
  end if;

  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Select your name before receiving the trolley.';
  end if;

  if p_customer_id is null then
    raise exception using errcode='22023', message='Confirmed customer is required.';
  end if;

  if v_contents not in ('CONTENTS','EMPTY') then
    raise exception using errcode='22023', message='Choose Laundry inside or Empty trolley.';
  end if;

  if exists(
    select 1
    from unnest(coalesce(p_product_codes,array[]::text[])) x
    where upper(trim(x)) not in ('CLOTHES','MOP')
  ) then
    raise exception using errcode='22023', message='Product selection contains an invalid value.';
  end if;

  select array_agg(distinct upper(trim(x)) order by upper(trim(x)))
  into v_products
  from unnest(coalesce(p_product_codes,array[]::text[])) x
  where upper(trim(x)) in ('CLOTHES','MOP');

  if coalesce(array_length(v_products,1),0)=0
     or array_length(v_products,1)>2 then
    raise exception using errcode='22023', message='Choose Clothes, MOP or Both.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='Trolley intake notes must be 1000 characters or fewer.';
  end if;

  if v_customer_override_reason is not null and length(v_customer_override_reason)>500 then
    raise exception using errcode='22023', message='Customer override reason must be 500 characters or fewer.';
  end if;

  if v_off_schedule_reason is not null and length(v_off_schedule_reason)>500 then
    raise exception using errcode='22023', message='Off-schedule reason must be 500 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code=v_shift_code
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  -- Operator must be an Actual/Planned Sorting staff candidate for the shift.
  if not exists (
    select 1
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift_code)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id'=p_operator_staff_id::text
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is not active in Sorting for this shift.';
  end if;

  if exists (
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
      and a.attendance_status='ABSENT'
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is marked absent. Correct attendance before receiving a trolley.';
  end if;

  select *
  into v_trolley
  from public.trolleys t
  where lower(t.trolley_code)=lower(v_code)
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode='P0002', message=format('Trolley not found: %s',v_code);
  end if;

  if v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    raise exception using
      errcode='23514',
      message=format('Trolley %s cannot be received while status is %s.',v_code,v_trolley.status);
  end if;

  if exists (
    select 1
    from public.sorting_trolley_intakes sti
    where sti.trolley_id=v_trolley.trolley_id
      and sti.created_at>=now()-interval '10 minutes'
  ) then
    raise exception using
      errcode='23505',
      message=format('Trolley %s was already received a few minutes ago.',v_code);
  end if;

  select *
  into v_customer
  from public.customers c
  where c.customer_id=p_customer_id
    and c.active=true
    and c.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='22023', message='Confirmed customer is not active.';
  end if;

  select *
  into v_suggestion
  from public.suggest_trolley_customer(v_code);

  if v_suggestion.open_stay_id is not null then
    v_confirmation_source := 'OPEN_STAY';
  elsif v_suggestion.suggested_customer_id=p_customer_id
        and coalesce(v_suggestion.suggestion_reason,'')='LAST_KNOWN_CUSTOMER' then
    v_confirmation_source := 'LAST_KNOWN_CUSTOMER';
  else
    v_confirmation_source := 'MANUAL_SELECTION';
  end if;

  if v_suggestion.suggested_customer_id is not null
     and v_suggestion.suggested_customer_id is distinct from p_customer_id
     and v_customer_override_reason is null then
    raise exception using
      errcode='22023',
      message='Customer differs from trolley history. Enter the reason before confirming.';
  end if;

  if p_scheduled_for_date is null then
    if v_off_schedule_reason is null then
      raise exception using
        errcode='22023',
        message='Off-schedule trolley intake requires a reason.';
    end if;
    v_relation := 'OFF_SCHEDULE';
  else
    if p_scheduled_for_date < v_business_date-1
       or p_scheduled_for_date > v_business_date+1 then
      raise exception using
        errcode='22023',
        message='Scheduled Date must be Yesterday, Today or Tomorrow for Sorting Intake.';
    end if;

    v_relation := case
      when p_scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      when p_scheduled_for_date=v_business_date then 'TODAY'
      else 'TOMORROW'
    end;
    v_off_schedule_reason := null;
  end if;

  -- Validate every selected product before closing physical custody.
  foreach v_product in array v_products loop
    if p_scheduled_for_date is not null then
      perform 1
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id=csv.schedule_version_id
       and sd.active=true
       and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id=sd.schedule_day_id
       and sp.active=true
      join public.product_types pt
        on pt.product_type_id=sp.product_type_id
       and pt.active=true
       and pt.deleted_at is null
      where csv.customer_id=p_customer_id
        and csv.status='PUBLISHED'
        and csv.effective_from<=p_scheduled_for_date
        and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
        and pt.product_code=v_product;

      if not found then
        raise exception using
          errcode='22023',
          message=format(
            '%s is not published for %s on %s. Choose the correct Scheduled Date or use Off schedule with a reason.',
            v_product,v_customer.customer_name,p_scheduled_for_date
          );
      end if;
    end if;
  end loop;

  -- Physical custody uses the actual calendar day. Operational grouping is
  -- preserved separately in sorting_trolley_intakes.business_date.
  v_receipt := public.confirm_trolley_sorting_arrival(
    p_trolley_code=>v_code,
    p_customer_id=>p_customer_id,
    p_arrived_on=>current_date,
    p_confirmation_source=>v_confirmation_source,
    p_notes=>v_notes
  );

  v_stay_id := nullif(v_receipt->>'stay_id','')::uuid;

  if v_stay_id is null then
    raise exception using errcode='P0001', message='Trolley lifecycle receipt did not return a stay ID.';
  end if;

  v_product_scope := case
    when array_length(v_products,1)=2 then 'BOTH'
    else v_products[1]
  end;

  insert into public.sorting_trolley_intakes(
    stay_id,trolley_id,trolley_code_snapshot,
    customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,physical_received_on,shift_id,shift_code_snapshot,arrived_at,
    contents_status,product_scope,scheduled_for_date,schedule_relation,
    confirmation_source,suggestion_reason,suggested_customer_id,
    customer_override_reason,off_schedule_reason,
    exception_type,review_status,
    operator_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,
    notes
  )
  values(
    v_stay_id,v_trolley.trolley_id,v_code,
    v_customer.customer_id,v_customer.customer_code,v_customer.customer_name,
    v_business_date,current_date,v_shift.shift_id,v_shift_code,now(),
    v_contents,v_product_scope,p_scheduled_for_date,v_relation,
    v_confirmation_source,v_suggestion.suggestion_reason,v_suggestion.suggested_customer_id,
    v_customer_override_reason,v_off_schedule_reason,
    nullif(v_receipt->>'exception_type',''),coalesce(v_receipt->>'review_status','NOT_REQUIRED'),
    p_operator_staff_id,v_actor_staff_id,auth.uid(),
    v_notes
  )
  returning * into v_intake;

  foreach v_product in array v_products loop
    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_schedule_product_id := null;
    v_production_order := null;
    v_planned_trolley_quantity := null;
    v_route_id := null;
    v_route_code := null;
    v_route_display_name := null;
    v_route_color := null;

    if p_scheduled_for_date is not null then
      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.schedule_product_id,
        sp.production_order,
        coalesce((
          select sum(req.quantity)::integer
          from public.customer_schedule_trolley_requirements req
          where req.schedule_day_id=sd.schedule_day_id
            and req.owner_schedule_product_id=sp.schedule_product_id
            and req.active=true
        ),0) as planned_trolley_quantity,
        r.route_id,
        r.route_code,
        r.display_name as route_display_name,
        r.route_color
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_schedule_product_id,
        v_production_order,
        v_planned_trolley_quantity,
        v_route_id,
        v_route_code,
        v_route_display_name,
        v_route_color
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id=csv.schedule_version_id
       and sd.active=true
       and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id=sd.schedule_day_id
       and sp.active=true
      join public.product_types pt
        on pt.product_type_id=sp.product_type_id
       and pt.active=true
       and pt.deleted_at is null
       and pt.product_code=v_product
      left join public.distribution_routes r
        on r.route_id=sd.default_route_id
       and r.deleted_at is null
      where csv.customer_id=p_customer_id
        and csv.status='PUBLISHED'
        and csv.effective_from<=p_scheduled_for_date
        and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
      order by csv.effective_from desc,csv.version_number desc
      limit 1;
    end if;

    v_flow_id := public.ensure_production_flow_item(
      p_customer_id,
      v_product,
      p_scheduled_for_date,
      v_business_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color
    );

    insert into public.sorting_trolley_intake_products(
      sorting_trolley_intake_id,
      product_code,
      scheduled_for_date,
      source_schedule_version_id,
      source_schedule_day_id,
      source_schedule_product_id,
      production_order_snapshot,
      planned_trolley_quantity_snapshot,
      route_id_snapshot,
      route_code_snapshot,
      route_display_name_snapshot,
      route_color_snapshot,
      production_flow_item_id
    )
    values(
      v_intake.sorting_trolley_intake_id,
      v_product,
      p_scheduled_for_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_planned_trolley_quantity,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color,
      v_flow_id
    )
    returning sorting_trolley_intake_product_id into v_child_id;

    perform public.append_production_flow_event(
      v_flow_id,
      case when v_contents='CONTENTS' then 'TROLLEY_RECEIVED_CONTENTS' else 'TROLLEY_RECEIVED_EMPTY' end,
      'INTAKE',
      20,
      'SORTING',
      v_business_date,
      v_intake.arrived_at,
      p_operator_staff_id,
      v_actor_staff_id,
      auth.uid(),
      'SORTING_V2',
      'sorting_trolley_intake_products',
      v_child_id::text,
      jsonb_build_object(
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
        'stay_id',v_stay_id,
        'trolley_id',v_trolley.trolley_id,
        'trolley_code',v_code,
        'customer_id',p_customer_id,
        'customer_name',v_customer.customer_name,
        'contents_status',v_contents,
        'product_code',v_product,
        'scheduled_for_date',p_scheduled_for_date,
        'schedule_relation',v_relation,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code,
        'review_status',v_intake.review_status,
        'exception_type',v_intake.exception_type,
        'physical_received_on',current_date
      )
    );

    v_product_payload := v_product_payload || jsonb_build_array(
      jsonb_build_object(
        'product_code',v_product,
        'production_flow_item_id',v_flow_id,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code
      )
    );
  end loop;

  insert into public.trolley_events(
    trolley_id,stay_id,event_type,customer_id,business_date,
    performed_by,source_application,reason,metadata
  )
  values(
    v_trolley.trolley_id,
    v_stay_id,
    case when v_contents='CONTENTS'
      then 'SORTING_CONTENTS_CONFIRMED'
      else 'SORTING_EMPTY_CONFIRMED'
    end,
    p_customer_id,
    v_business_date,
    p_operator_staff_id,
    'SORTING_V2',
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    jsonb_build_object(
      'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
      'contents_status',v_contents,
      'product_scope',v_product_scope,
      'product_codes',to_jsonb(v_products),
      'scheduled_for_date',p_scheduled_for_date,
      'schedule_relation',v_relation,
      'physical_received_on',current_date,
      'recorded_by_staff_id',v_actor_staff_id
    )
  );

  -- Trolley Intake is real presence evidence. Do not leave a staff member as
  -- inferred AUTO_ABSENT after they physically record an intake.
  insert into public.sorting_daily_staff_attendance(
    business_date,shift_id,staff_id,
    attendance_status,absence_reason,notes,source,
    created_by_auth_user_id,updated_by_auth_user_id
  )
  select
    v_business_date,v_shift.shift_id,p_operator_staff_id,
    'PRESENT',null,
    'Presence evidence from Sorting Trolley Intake ' || v_code || '.',
    'SORTING_TROLLEY_INTAKE',
    auth.uid(),auth.uid()
  where not exists(
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
  );

  get diagnostics v_attendance_inserted = row_count;

  if v_attendance_inserted>0 then
    insert into public.audit_log(
      actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
      new_data,reason,source_application
    )
    values(
      auth.uid(),v_actor_staff_id,
      'SORTING_ATTENDANCE_EVIDENCE_TROLLEY_INTAKE',
      'sorting_daily_staff_attendance',
      p_operator_staff_id::text || ':' || v_business_date::text || ':' || v_shift.shift_id::text,
      jsonb_build_object(
        'business_date',v_business_date,
        'shift_code',v_shift_code,
        'staff_id',p_operator_staff_id,
        'evidence','TROLLEY_INTAKE',
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id
      ),
      'Physical trolley intake recorded.',
      'SORTING_V2'
    );
  end if;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    new_data,reason,source_application
  )
  values(
    auth.uid(),v_actor_staff_id,
    case when v_contents='CONTENTS'
      then 'SORTING_TROLLEY_CONTENTS_INTAKE_RECORDED'
      else 'SORTING_TROLLEY_EMPTY_INTAKE_RECORDED'
    end,
    'sorting_trolley_intakes',
    v_intake.sorting_trolley_intake_id::text,
    to_jsonb(v_intake) || jsonb_build_object('products',v_product_payload),
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status','success',
    'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
    'stay_id',v_stay_id,
    'trolley_code',v_code,
    'customer_id',p_customer_id,
    'customer_name',v_customer.customer_name,
    'business_date',v_business_date,
    'physical_received_on',current_date,
    'contents_status',v_contents,
    'product_scope',v_product_scope,
    'scheduled_for_date',p_scheduled_for_date,
    'schedule_relation',v_relation,
    'review_status',v_intake.review_status,
    'products',v_product_payload,
    'message',case
      when v_intake.review_status in ('PENDING','UNDER_REVIEW')
        then format('%s received. Trolley history needs review.',v_code)
      when v_contents='EMPTY'
        then format('%s received empty. No wash record was created.',v_code)
      else format('%s received with laundry. Customer is now visible in the wash queue.',v_code)
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Intake activity prevents contradictory manual absence
-- ---------------------------------------------------------------------

create or replace function public.sorting_guard_absent_trolley_activity()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.attendance_status='ABSENT'
     and exists(
       select 1
       from public.sorting_trolley_intakes sti
       where sti.business_date=new.business_date
         and sti.shift_id=new.shift_id
         and sti.operator_staff_id=new.staff_id
     ) then
    raise exception using
      errcode='22023',
      message='This staff member has recorded Trolley Intake activity and cannot be marked absent.';
  end if;

  return new;
end;
$$;

drop trigger if exists sorting_attendance_trolley_activity_guard
  on public.sorting_daily_staff_attendance;

create trigger sorting_attendance_trolley_activity_guard
before insert or update of attendance_status
on public.sorting_daily_staff_attendance
for each row
execute function public.sorting_guard_absent_trolley_activity();

revoke all on function public.sorting_guard_absent_trolley_activity()
  from public, anon, authenticated;

-- Staff dashboard V2 exposes intake activity so the frontend can suppress
-- contradictory absence actions without adding visual clutter.
create or replace function public.get_sorting_staff_dashboard_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date;
  v_shift_id uuid;
  v_staff jsonb := '[]'::jsonb;
begin
  v_base := public.get_sorting_staff_dashboard_context(p_shift_code);
  v_business_date := (v_base->>'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  select coalesce(jsonb_agg(
    staff_row.value || jsonb_build_object(
      'trolley_intake_count',(
        select count(*)::integer
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.operator_staff_id=nullif(staff_row.value->>'staff_id','')::uuid
      ),
      'has_actual_operational_activity',
        coalesce((staff_row.value->'performance'->>'total_loads')::integer,0)>0
        or exists(
          select 1
          from public.sorting_trolley_intakes sti
          where sti.business_date=v_business_date
            and sti.shift_id=v_shift_id
            and sti.operator_staff_id=nullif(staff_row.value->>'staff_id','')::uuid
        )
    )
    order by lower(staff_row.value->>'display_name')
  ),'[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base->'staff','[]'::jsonb)) staff_row;

  return v_base || jsonb_build_object(
    'staff',v_staff,
    'actual_activity_sources',jsonb_build_array('WASHING','TROLLEY_INTAKE','TIME_ADJUSTMENT','MANUAL_POSITION')
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Close browser write shortcuts that bypass Contents/Empty + Date + Product
-- ---------------------------------------------------------------------

revoke execute on function public.record_sorting_trolley_intake(text,uuid,text)
  from authenticated;
revoke execute on function public.confirm_trolley_sorting_arrival(text,uuid,date,text,text)
  from authenticated;
revoke execute on function public.receive_trolley_from_customer(text,uuid,date,text,text,text)
  from authenticated;

-- New controlled browser contracts.
revoke all on function public.get_sorting_trolley_intake_context_v2(text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_trolley_intake_preview_v2(text,text)
  from public, anon, authenticated;
revoke all on function public.record_sorting_trolley_intake_v2(
  text,text,uuid,uuid,text,date,text[],text,text,text
) from public, anon, authenticated;
revoke all on function public.get_sorting_staff_dashboard_context_v2(text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_trolley_intake_context_v2(text)
  to authenticated;
grant execute on function public.get_sorting_trolley_intake_preview_v2(text,text)
  to authenticated;
grant execute on function public.record_sorting_trolley_intake_v2(
  text,text,uuid,uuid,text,date,text[],text,text,text
) to authenticated;
grant execute on function public.get_sorting_staff_dashboard_context_v2(text)
  to authenticated;

comment on table public.sorting_trolley_intakes is
  'Sorting physical trolley intake evidence. Captures actual performer, operational Business Date, physical receipt date, Contents/Empty, customer and schedule selection without duplicating trolley custody history.';

comment on table public.sorting_trolley_intake_products is
  'Per-product bridge from a physical Sorting trolley intake to the stable Production Flow Item. A shared trolley may create both CLOTHES and MOP rows while remaining one physical intake.';

comment on function public.record_sorting_trolley_intake_v2(
  text,text,uuid,uuid,text,date,text[],text,text,text
) is
  'Authoritative Sorting Trolley Intake write. Requires operator, customer, scheduled date or explicit off-schedule reason, Contents/Empty and Clothes/MOP/Both; appends trolley and Production Flow evidence atomically.';

comment on function public.sorting_trolley_intake_state(integer,integer,integer,integer,integer,integer) is
  'Deterministic Trolley Intake operational state. NOTHING_TO_WASH requires all known/planned receipts explicitly EMPTY, no contents and no wash; Route adjacency is never evidence.';

commit;
