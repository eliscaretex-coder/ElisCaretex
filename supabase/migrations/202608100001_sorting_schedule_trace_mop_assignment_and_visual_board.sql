-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100001_sorting_schedule_trace_mop_assignment_and_visual_board
--
-- Purpose:
--   * preserve the scheduled production date/day on each washed customer;
--   * support washing tomorrow's customer today without marking it UNSCHEDULED;
--   * snapshot Route identity/color into the washing trace;
--   * provide a Today + work-ahead customer board;
--   * identify exactly one daily Sorting staff member as MOP when assigned;
--   * keep Production Roster immutable (Roster = Planned, workstation = Actual).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Extend per-customer washing trace
-- ---------------------------------------------------------------------

alter table public.sorting_wash_run_customers
  add column if not exists scheduled_for_date date,
  add column if not exists scheduled_weekday_snapshot smallint,
  add column if not exists scheduled_weekday_name_snapshot text,
  add column if not exists route_id_snapshot uuid
    references public.distribution_routes(route_id) on delete set null,
  add column if not exists route_code_snapshot text,
  add column if not exists route_display_name_snapshot text,
  add column if not exists route_color_snapshot text;

alter table public.sorting_wash_run_customers
  drop constraint if exists sorting_wash_run_customers_relation_check;

alter table public.sorting_wash_run_customers
  add constraint sorting_wash_run_customers_relation_check
    check (
      schedule_relation in (
        'TODAY',
        'EARLY',
        'LATE',
        'UNSCHEDULED',
        'NOT_APPLICABLE'
      )
    );

alter table public.sorting_wash_run_customers
  drop constraint if exists sorting_wash_run_customers_weekday_check;

alter table public.sorting_wash_run_customers
  add constraint sorting_wash_run_customers_weekday_check
    check (
      scheduled_weekday_snapshot is null
      or scheduled_weekday_snapshot between 1 and 7
    );

-- Existing TODAY traces already point to the authoritative schedule product.
-- Backfill their date/day/route snapshot using the wash Business Date.
update public.sorting_wash_run_customers wrc
set scheduled_for_date = coalesce(wrc.scheduled_for_date, wr.business_date),
    scheduled_weekday_snapshot = coalesce(
      wrc.scheduled_weekday_snapshot,
      sd.production_weekday
    ),
    scheduled_weekday_name_snapshot = coalesce(
      nullif(wrc.scheduled_weekday_name_snapshot, ''),
      trim(to_char(wr.business_date, 'Day'))
    ),
    route_id_snapshot = coalesce(wrc.route_id_snapshot, r.route_id),
    route_code_snapshot = coalesce(nullif(wrc.route_code_snapshot, ''), r.route_code),
    route_display_name_snapshot = coalesce(
      nullif(wrc.route_display_name_snapshot, ''),
      r.display_name
    ),
    route_color_snapshot = coalesce(
      nullif(wrc.route_color_snapshot, ''),
      r.route_color
    )
from public.sorting_wash_runs wr,
     public.customer_schedule_products sp
join public.customer_schedule_days sd
  on sd.schedule_day_id = sp.schedule_day_id
left join public.distribution_routes r
  on r.route_id = sd.default_route_id
where wr.wash_run_id = wrc.wash_run_id
  and sp.schedule_product_id = wrc.source_schedule_product_id
  and wrc.schedule_relation = 'TODAY'
  and wrc.source_schedule_product_id is not null;

create index if not exists sorting_wash_run_customers_scheduled_date_idx
  on public.sorting_wash_run_customers
  (scheduled_for_date, source_schedule_product_id, customer_id);

-- ---------------------------------------------------------------------
-- 2. Daily Sorting work mode (one MOP staff per shift when assigned)
-- ---------------------------------------------------------------------

create table if not exists public.sorting_daily_staff_modes (
  sorting_daily_staff_mode_id uuid primary key default gen_random_uuid(),
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  work_mode text not null default 'CLOTHES',
  source text not null default 'SORTING_WORKSTATION',
  notes text,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint sorting_daily_staff_modes_mode_check
    check (work_mode in ('CLOTHES', 'MOP')),
  constraint sorting_daily_staff_modes_unique
    unique (business_date, shift_id, staff_id)
);

create unique index if not exists sorting_daily_staff_modes_one_mop_uidx
  on public.sorting_daily_staff_modes (business_date, shift_id)
  where work_mode = 'MOP';

alter table public.sorting_daily_staff_modes enable row level security;
revoke all on table public.sorting_daily_staff_modes from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Staff context V2 with Clothes/MOP identification
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_staff_work_context_v2(
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
  v_mop_staff_id uuid;
  v_mop_staff_name text;
begin
  v_base := public.get_sorting_staff_work_context(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'work_mode', coalesce(mode_row.work_mode, 'CLOTHES'),
      'work_mode_explicit', mode_row.sorting_daily_staff_mode_id is not null
    )
    order by lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.sorting_daily_staff_modes mode_row
    on mode_row.business_date = v_business_date
   and mode_row.shift_id = v_shift_id
   and mode_row.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid;

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_mop_staff_id, v_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'mop_staff_id', v_mop_staff_id,
    'mop_staff_name', v_mop_staff_name,
    'mop_assignment_missing', v_mop_staff_id is null,
    'work_mode_source', 'SORTING_DAILY_ACTUAL'
  );
end;
$$;

create or replace function public.set_sorting_mop_staff(
  p_shift_code text,
  p_staff_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_context jsonb;
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  v_context := public.get_sorting_staff_work_context(v_shift_code);

  select staff_row.value ->> 'display_name'
  into v_staff_name
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb)) staff_row
  where nullif(staff_row.value ->> 'staff_id', '')::uuid = p_staff_id
  limit 1;

  if v_staff_name is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff member is not active in Sorting for this shift.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext(v_business_date::text || ':' || v_shift.shift_id::text || ':SORTING_MOP')
  );

  update public.sorting_daily_staff_modes
  set work_mode = 'CLOTHES',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid()
  where business_date = v_business_date
    and shift_id = v_shift.shift_id
    and work_mode = 'MOP'
    and staff_id <> p_staff_id;

  insert into public.sorting_daily_staff_modes (
    business_date,
    shift_id,
    staff_id,
    work_mode,
    source,
    created_by_auth_user_id,
    updated_by_auth_user_id
  )
  values (
    v_business_date,
    v_shift.shift_id,
    p_staff_id,
    'MOP',
    'SORTING_WORKSTATION',
    auth.uid(),
    auth.uid()
  )
  on conflict (business_date, shift_id, staff_id)
  do update
  set work_mode = 'MOP',
      source = 'SORTING_WORKSTATION',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid();

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'mop_staff_id', p_staff_id,
    'mop_staff_name', v_staff_name,
    'message', format('%s is assigned to MOP for this Sorting shift.', v_staff_name)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Customer board V2: today plus tomorrow work-ahead context
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_customer_board_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_rows jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  with board_days as (
    select
      v_business_date as scheduled_for_date,
      'TODAY'::text as day_relation,
      0::integer as day_offset
    union all
    select
      v_business_date + 1,
      'TOMORROW'::text,
      1
  ),
  board_rows as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      extract(isodow from bd.scheduled_for_date)::smallint as scheduled_weekday,
      trim(to_char(bd.scheduled_for_date, 'Day')) as scheduled_weekday_name,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.expected_kg,
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
        where req.schedule_day_id = sd.schedule_day_id
          and req.owner_schedule_product_id = sp.schedule_product_id
          and req.active = true
      ), 0) as planned_trolley_quantity,
      (
        select count(*)::integer
        from public.sorting_wash_run_customers wrc
        join public.sorting_wash_runs wr
          on wr.wash_run_id = wrc.wash_run_id
        where wr.status = 'RECORDED'
          and wrc.customer_id = c.customer_id
          and wrc.wash_type_snapshot = pt.product_code
          and wrc.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc.scheduled_for_date, wr.business_date) = bd.scheduled_for_date
      ) as wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2
          on wr2.wash_run_id = wrc2.wash_run_id
        where wr2.status = 'RECORDED'
          and wrc2.customer_id = c.customer_id
          and wrc2.wash_type_snapshot = pt.product_code
          and wrc2.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc2.scheduled_for_date, wr2.business_date) = bd.scheduled_for_date
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) as last_wash_code,
      (
        select wr3.business_date
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3
          on wr3.wash_run_id = wrc3.wash_run_id
        where wr3.status = 'RECORDED'
          and wrc3.customer_id = c.customer_id
          and wrc3.wash_type_snapshot = pt.product_code
          and wrc3.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc3.scheduled_for_date, wr3.business_date) = bd.scheduled_for_date
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) as last_washed_on
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status = 'PUBLISHED'
     and csv.effective_from <= bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until >= bd.scheduled_for_date)
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active = true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active = true
     and sd.production_weekday = extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id = sd.schedule_day_id
     and sp.active = true
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
     and pt.active = true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES', 'MOP')
    left join public.distribution_routes r
      on r.route_id = sd.default_route_id
     and r.deleted_at is null
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', br.customer_id,
      'customer_code', br.customer_code,
      'customer_name', br.customer_name,
      'product_code', br.product_code,
      'production_order', br.production_order,
      'expected_kg', br.expected_kg,
      'production_instructions', br.production_instructions,
      'schedule_version_id', br.schedule_version_id,
      'schedule_day_id', br.schedule_day_id,
      'schedule_product_id', br.schedule_product_id,
      'scheduled_for_date', br.scheduled_for_date,
      'scheduled_weekday', br.scheduled_weekday,
      'scheduled_weekday_name', br.scheduled_weekday_name,
      'day_relation', br.day_relation,
      'day_offset', br.day_offset,
      'route_id', br.route_id,
      'route_code', br.route_code,
      'route_display_name', br.route_display_name,
      'route_color', br.route_color,
      'planned_trolley_quantity', br.planned_trolley_quantity,
      'wash_count', br.wash_count,
      'last_wash_code', br.last_wash_code,
      'last_washed_on', br.last_washed_on,
      'status', case when br.wash_count > 0 then 'WASHED' else 'PENDING' end
    )
    order by
      br.day_offset,
      case br.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
      br.production_order nulls last,
      lower(br.customer_name),
      br.customer_code
  ), '[]'::jsonb)
  into v_rows
  from board_rows br;

  return jsonb_build_object(
    'business_date', v_business_date,
    'customers', v_rows,
    'source', 'PUBLISHED_CUSTOMER_SCHEDULE_TODAY_AND_TOMORROW'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Washing context V2: recent 3-day history + trace presentation
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_washing_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_base jsonb;
  v_recent_washes jsonb := '[]'::jsonb;
begin
  v_base := public.get_sorting_washing_context(p_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id', q.wash_run_id,
      'wash_code', q.wash_code,
      'business_date', q.business_date,
      'shift_code', q.shift_code_snapshot,
      'washer_code', q.washer_code_snapshot,
      'washer_name', q.washer_name_snapshot,
      'operator_staff_id', q.operator_staff_id,
      'operator_name', q.operator_name_snapshot,
      'wash_type', q.wash_type,
      'started_at', q.started_at,
      'registered_at', q.registered_at,
      'total_weight_kg', q.total_weight_kg,
      'customers', q.customers
    )
    order by q.business_date desc, q.started_at desc, q.registered_at desc
  ), '[]'::jsonb)
  into v_recent_washes
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id', wrc.wash_run_customer_id,
            'trace_code', wrc.trace_code,
            'customer_id', wrc.customer_id,
            'customer_code', wrc.customer_code_snapshot,
            'customer_name', wrc.customer_name_snapshot,
            'schedule_relation', wrc.schedule_relation,
            'scheduled_for_date', wrc.scheduled_for_date,
            'scheduled_weekday',
              coalesce(
                wrc.scheduled_weekday_name_snapshot,
                case
                  when wrc.scheduled_for_date is null then null
                  else trim(to_char(wrc.scheduled_for_date, 'Day'))
                end
              ),
            'route_code',
              coalesce(nullif(wrc.route_code_snapshot, ''), r.route_code),
            'route_display_name',
              coalesce(nullif(wrc.route_display_name_snapshot, ''), r.display_name),
            'route_color',
              coalesce(nullif(wrc.route_color_snapshot, ''), r.route_color)
          )
          order by lower(wrc.customer_name_snapshot), wrc.trace_code
        )
        from public.sorting_wash_run_customers wrc
        left join public.customer_schedule_products sp
          on sp.schedule_product_id = wrc.source_schedule_product_id
        left join public.customer_schedule_days sd
          on sd.schedule_day_id = sp.schedule_day_id
        left join public.distribution_routes r
          on r.route_id = sd.default_route_id
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) as customers
    from public.sorting_wash_runs wr
    where wr.business_date between (v_business_date - 2) and v_business_date
      and wr.status = 'RECORDED'
    order by wr.business_date desc, wr.started_at desc, wr.registered_at desc
    limit 80
  ) q;

  return v_base || jsonb_build_object(
    'recent_washes', v_recent_washes,
    'recent_wash_window_days', 3
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Base Washing save alignment: planned OR manual Actual Sorting staff
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_wash_run(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_ids uuid[],
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_wash_type text := upper(trim(coalesce(p_wash_type,'')));
  v_shift public.shifts%rowtype;
  v_washer public.sorting_washers%rowtype;
  v_operator public.staff_members%rowtype;
  v_context jsonb;
  v_sorting_area_id uuid;
  v_started_at timestamptz;
  v_customer_ids uuid[];
  v_customer_count integer;
  v_active_customer_count integer;
  v_wash_run_id uuid;
  v_wash_code text;
  v_item record;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_schedule_product_id uuid;
  v_production_order integer;
  v_expected_kg numeric(12,2);
  v_production_instructions text;
  v_schedule_relation text;
  v_trace_code text;
  v_trace_rows jsonb := '[]'::jsonb;
  v_unscheduled_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;
  if v_wash_type not in ('CLOTHES','MOP','OTHERS') then
    raise exception using errcode='22023', message='Wash type must be CLOTHES, MOP or OTHERS.';
  end if;
  if p_washer_id is null then
    raise exception using errcode='22023', message='Washer is required.';
  end if;
  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Operator is required.';
  end if;
  if p_start_time is null then
    raise exception using errcode='22023', message='Start time is required.';
  end if;
  if p_weight_kg is null or p_weight_kg <= 0 then
    raise exception using errcode='22023', message='Weight must be greater than zero.';
  end if;
  if length(coalesce(p_notes,'')) > 1000 then
    raise exception using errcode='22023', message='Notes must be 1000 characters or fewer.';
  end if;

  select array_agg(x.customer_id order by x.first_position)
  into v_customer_ids
  from (
    select customer_id, min(position) first_position
    from unnest(coalesce(p_customer_ids,array[]::uuid[]))
      with ordinality as u(customer_id,position)
    where customer_id is not null
    group by customer_id
  ) x;

  v_customer_count := coalesce(array_length(v_customer_ids,1),0);
  if v_customer_count = 0 then
    raise exception using errcode='22023', message='At least one customer is required.';
  end if;
  if v_customer_count > 20 then
    raise exception using errcode='22023', message='A washing load cannot contain more than 20 customers.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  select * into v_washer
  from public.sorting_washers w
  where w.washer_id = p_washer_id
    and w.active
    and w.deleted_at is null;

  if not found then
    raise exception using errcode='P0002', message='Selected washer is not available.';
  end if;

  if p_weight_kg > v_washer.capacity_kg then
    raise exception using
      errcode='22023',
      message=format('Weight (%s KG) exceeds %s capacity (%s KG).',
        p_weight_kg, v_washer.washer_code, v_washer.capacity_kg);
  end if;

  select * into v_operator
  from public.staff_members sm
  where sm.staff_id = p_operator_staff_id
    and sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null;

  if not found then
    raise exception using errcode='P0002', message='Selected operator is not active production staff.';
  end if;

  v_context := public.get_sorting_daily_context(v_business_date, v_shift_code);

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_context -> 'planned_staff','[]'::jsonb)) staff_row
    where nullif(staff_row ->> 'staff_id','')::uuid = p_operator_staff_id
  )
  and not exists (
    select 1
    from public.work_sessions ws
    where ws.work_date = v_business_date
      and ws.staff_id = p_operator_staff_id
      and ws.shift_id = v_shift.shift_id
      and ws.area_id = v_sorting_area_id
      and ws.status <> 'CANCELLED'
  ) then
    raise exception using
      errcode='22023',
      message=format(
        '%s is not active in Sorting for %s %s. Add the person to Actual Sorting staffing first.',
        v_operator.display_name, v_business_date, v_shift.shift_name
      );
  end if;

  select count(*)
  into v_active_customer_count
  from public.customers c
  where c.customer_id = any(v_customer_ids)
    and c.active
    and c.deleted_at is null;

  if v_active_customer_count <> v_customer_count then
    raise exception using errcode='22023', message='One or more selected customers are inactive or unavailable.';
  end if;

  v_started_at := (
    (v_business_date::text || ' ' || p_start_time::text)::timestamp
    at time zone 'Europe/Dublin'
  );

  if v_started_at > now() + interval '2 minutes' then
    raise exception using errcode='22023', message='Start time cannot be in the future.';
  end if;

  -- Per-washer lock supports two concurrent Sorting PCs safely.
  perform pg_advisory_xact_lock(hashtext(v_washer.washer_id::text));

  if exists (
    select 1
    from public.sorting_wash_runs wr
    where wr.washer_id = v_washer.washer_id
      and wr.business_date = v_business_date
      and wr.status = 'RECORDED'
      and abs(extract(epoch from (wr.started_at - v_started_at))) < 600
  ) then
    raise exception using
      errcode='23505',
      message=format('%s already has a washing load recorded within 10 minutes of this start time.',
        v_washer.washer_code);
  end if;

  loop
    v_wash_code := 'W' || to_char(v_business_date,'YYYYMMDD') || '-' ||
      upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    exit when not exists (
      select 1 from public.sorting_wash_runs wr where wr.wash_code = v_wash_code
    );
  end loop;

  insert into public.sorting_wash_runs (
    wash_code, business_date, shift_id, shift_code_snapshot,
    washer_id, washer_code_snapshot, washer_name_snapshot, washer_capacity_kg_snapshot,
    operator_staff_id, operator_name_snapshot,
    wash_type, started_at, total_weight_kg, notes,
    source_application, recorded_by_auth_user_id, metadata
  )
  values (
    v_wash_code, v_business_date, v_shift.shift_id, v_shift.shift_code,
    v_washer.washer_id, v_washer.washer_code, v_washer.washer_name, v_washer.capacity_kg,
    v_operator.staff_id, v_operator.display_name,
    v_wash_type, v_started_at, p_weight_kg, nullif(trim(p_notes),''),
    'SORTING_V2', auth.uid(),
    jsonb_build_object(
      'roster_version_id', v_context -> 'roster' ->> 'roster_version_id',
      'roster_version_number', v_context -> 'roster' ->> 'version_number'
    )
  )
  returning wash_run_id into v_wash_run_id;

  for v_item in
    select
      u.position,
      c.customer_id,
      c.customer_code,
      c.customer_name
    from unnest(v_customer_ids) with ordinality as u(customer_id,position)
    join public.customers c on c.customer_id = u.customer_id
    order by u.position
  loop
    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_schedule_product_id := null;
    v_production_order := null;
    v_expected_kg := null;
    v_production_instructions := null;

    if v_wash_type in ('CLOTHES','MOP') then
      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.schedule_product_id,
        sp.production_order,
        sp.expected_kg,
        sp.production_instructions
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_schedule_product_id,
        v_production_order,
        v_expected_kg,
        v_production_instructions
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id = csv.schedule_version_id
       and sd.active
       and sd.production_weekday = extract(isodow from v_business_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id = sd.schedule_day_id
       and sp.active
      join public.product_types pt
        on pt.product_type_id = sp.product_type_id
       and pt.active
       and pt.deleted_at is null
       and pt.product_code = v_wash_type
      where csv.customer_id = v_item.customer_id
        and csv.status = 'PUBLISHED'
        and csv.effective_from <= v_business_date
        and (csv.effective_until is null or csv.effective_until >= v_business_date)
      order by csv.effective_from desc, csv.version_number desc
      limit 1;

      if v_schedule_product_id is null then
        v_schedule_relation := 'UNSCHEDULED';
        v_unscheduled_count := v_unscheduled_count + 1;
      else
        v_schedule_relation := 'TODAY';
      end if;
    else
      v_schedule_relation := 'NOT_APPLICABLE';
    end if;

    v_trace_code := v_wash_code || '-' || lpad(v_item.position::text,2,'0');

    insert into public.sorting_wash_run_customers (
      trace_code, wash_run_id, customer_id,
      customer_code_snapshot, customer_name_snapshot, wash_type_snapshot,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id,
      production_order_snapshot, expected_kg_snapshot, production_instructions_snapshot,
      schedule_relation, metadata
    )
    values (
      v_trace_code, v_wash_run_id, v_item.customer_id,
      v_item.customer_code, v_item.customer_name, v_wash_type,
      v_schedule_version_id, v_schedule_day_id, v_schedule_product_id,
      v_production_order, v_expected_kg, v_production_instructions,
      v_schedule_relation,
      jsonb_build_object('trace_role','SORTING_WASH_CUSTOMER','future_processing_link',true)
    );

    v_trace_rows := v_trace_rows || jsonb_build_array(
      jsonb_build_object(
        'trace_code', v_trace_code,
        'customer_id', v_item.customer_id,
        'customer_code', v_item.customer_code,
        'customer_name', v_item.customer_name,
        'schedule_relation', v_schedule_relation,
        'source_schedule_product_id', v_schedule_product_id
      )
    );
  end loop;

  return jsonb_build_object(
    'status','success',
    'wash_run_id',v_wash_run_id,
    'wash_code',v_wash_code,
    'business_date',v_business_date,
    'shift_code',v_shift.shift_code,
    'washer_code',v_washer.washer_code,
    'operator_staff_id',v_operator.staff_id,
    'operator_name',v_operator.display_name,
    'wash_type',v_wash_type,
    'started_at',v_started_at,
    'weight_kg',p_weight_kg,
    'customer_count',v_customer_count,
    'unscheduled_customer_count',v_unscheduled_count,
    'trace_rows',v_trace_rows,
    'message',case
      when v_unscheduled_count > 0 then
        format('Washing %s saved. %s customer(s) are outside today''s published %s schedule and remain traceable as UNSCHEDULED.',
          v_wash_code,v_unscheduled_count,v_wash_type)
      else format('Washing %s saved successfully.',v_wash_code)
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Washing save V2 with explicit customer schedule selection
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_wash_run_v2(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_wash_type text := upper(trim(coalesce(p_wash_type, '')));
  v_customer_ids uuid[];
  v_selection_count integer;
  v_unique_customer_count integer;
  v_result jsonb;
  v_wash_run_id uuid;
  v_selection record;
  v_customer_id uuid;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_production_order integer;
  v_expected_kg numeric(12,2);
  v_production_instructions text;
  v_weekday smallint;
  v_weekday_name text;
  v_route_id uuid;
  v_route_code text;
  v_route_display_name text;
  v_route_color text;
  v_relation text;
  v_trace_rows jsonb := '[]'::jsonb;
  v_unscheduled_count integer := 0;
  v_early_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  if p_customer_selections is null
     or jsonb_typeof(p_customer_selections) <> 'array'
     or jsonb_array_length(p_customer_selections) = 0 then
    raise exception using errcode = '22023', message = 'At least one customer selection is required.';
  end if;

  select
    array_agg(nullif(item.value ->> 'customer_id', '')::uuid order by item.ordinality),
    count(*)::integer,
    count(distinct nullif(item.value ->> 'customer_id', '')::uuid)::integer
  into v_customer_ids, v_selection_count, v_unique_customer_count
  from jsonb_array_elements(p_customer_selections) with ordinality item(value, ordinality);

  if v_customer_ids is null
     or array_position(v_customer_ids, null) is not null then
    raise exception using errcode = '22023', message = 'Every customer selection requires a valid customer_id.';
  end if;

  if v_selection_count <> v_unique_customer_count then
    raise exception using
      errcode = '22023',
      message = 'The same customer cannot be linked to two scheduled days in one washer load.';
  end if;

  v_result := public.save_sorting_wash_run(
    p_shift_code => p_shift_code,
    p_washer_id => p_washer_id,
    p_operator_staff_id => p_operator_staff_id,
    p_start_time => p_start_time,
    p_weight_kg => p_weight_kg,
    p_wash_type => v_wash_type,
    p_customer_ids => v_customer_ids,
    p_notes => p_notes
  );

  v_wash_run_id := nullif(v_result ->> 'wash_run_id', '')::uuid;

  for v_selection in
    select item.value as selection, item.ordinality
    from jsonb_array_elements(p_customer_selections) with ordinality item(value, ordinality)
    order by item.ordinality
  loop
    v_customer_id := nullif(v_selection.selection ->> 'customer_id', '')::uuid;
    v_schedule_product_id := nullif(v_selection.selection ->> 'schedule_product_id', '')::uuid;
    v_scheduled_for_date := nullif(v_selection.selection ->> 'scheduled_for_date', '')::date;

    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_production_order := null;
    v_expected_kg := null;
    v_production_instructions := null;
    v_weekday := null;
    v_weekday_name := null;
    v_route_id := null;
    v_route_code := null;
    v_route_display_name := null;
    v_route_color := null;

    if v_wash_type in ('CLOTHES', 'MOP') and v_schedule_product_id is not null then
      if v_scheduled_for_date is null then
        raise exception using
          errcode = '22023',
          message = 'Scheduled date is required for a scheduled customer selection.';
      end if;

      if v_scheduled_for_date < v_business_date - 2
         or v_scheduled_for_date > v_business_date + 2 then
        raise exception using
          errcode = '22023',
          message = 'Scheduled customer date must be within two days of the washing Business Date.';
      end if;

      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.production_order,
        sp.expected_kg,
        sp.production_instructions,
        sd.production_weekday,
        trim(to_char(v_scheduled_for_date, 'Day')),
        r.route_id,
        r.route_code,
        r.display_name,
        r.route_color
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_production_order,
        v_expected_kg,
        v_production_instructions,
        v_weekday,
        v_weekday_name,
        v_route_id,
        v_route_code,
        v_route_display_name,
        v_route_color
      from public.customer_schedule_products sp
      join public.customer_schedule_days sd
        on sd.schedule_day_id = sp.schedule_day_id
       and sd.active = true
      join public.customer_schedule_versions csv
        on csv.schedule_version_id = sd.schedule_version_id
       and csv.status = 'PUBLISHED'
       and csv.customer_id = v_customer_id
       and csv.effective_from <= v_scheduled_for_date
       and (csv.effective_until is null or csv.effective_until >= v_scheduled_for_date)
      join public.product_types pt
        on pt.product_type_id = sp.product_type_id
       and pt.active = true
       and pt.deleted_at is null
       and pt.product_code = v_wash_type
      left join public.distribution_routes r
        on r.route_id = sd.default_route_id
       and r.deleted_at is null
      where sp.schedule_product_id = v_schedule_product_id
        and sp.active = true
        and sd.production_weekday = extract(isodow from v_scheduled_for_date)::smallint
      limit 1;

      if v_schedule_day_id is null then
        raise exception using
          errcode = '22023',
          message = 'The selected customer schedule does not match the selected product/date.';
      end if;

      v_relation := case
        when v_scheduled_for_date = v_business_date then 'TODAY'
        when v_scheduled_for_date > v_business_date then 'EARLY'
        else 'LATE'
      end;

      if v_relation = 'EARLY' then
        v_early_count := v_early_count + 1;
      end if;

      update public.sorting_wash_run_customers wrc
      set source_schedule_version_id = v_schedule_version_id,
          source_schedule_day_id = v_schedule_day_id,
          source_schedule_product_id = v_schedule_product_id,
          production_order_snapshot = v_production_order,
          expected_kg_snapshot = v_expected_kg,
          production_instructions_snapshot = v_production_instructions,
          schedule_relation = v_relation,
          scheduled_for_date = v_scheduled_for_date,
          scheduled_weekday_snapshot = v_weekday,
          scheduled_weekday_name_snapshot = v_weekday_name,
          route_id_snapshot = v_route_id,
          route_code_snapshot = v_route_code,
          route_display_name_snapshot = v_route_display_name,
          route_color_snapshot = v_route_color
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;

    elsif v_wash_type in ('CLOTHES', 'MOP') then
      v_unscheduled_count := v_unscheduled_count + 1;

      update public.sorting_wash_run_customers wrc
      set source_schedule_version_id = null,
          source_schedule_day_id = null,
          source_schedule_product_id = null,
          production_order_snapshot = null,
          expected_kg_snapshot = null,
          production_instructions_snapshot = null,
          schedule_relation = 'UNSCHEDULED',
          scheduled_for_date = null,
          scheduled_weekday_snapshot = null,
          scheduled_weekday_name_snapshot = null,
          route_id_snapshot = null,
          route_code_snapshot = null,
          route_display_name_snapshot = null,
          route_color_snapshot = null
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;

    else
      update public.sorting_wash_run_customers wrc
      set schedule_relation = 'NOT_APPLICABLE',
          scheduled_for_date = null,
          scheduled_weekday_snapshot = null,
          scheduled_weekday_name_snapshot = null,
          route_id_snapshot = null,
          route_code_snapshot = null,
          route_display_name_snapshot = null,
          route_color_snapshot = null
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;
    end if;
  end loop;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'trace_code', wrc.trace_code,
      'customer_id', wrc.customer_id,
      'customer_code', wrc.customer_code_snapshot,
      'customer_name', wrc.customer_name_snapshot,
      'schedule_relation', wrc.schedule_relation,
      'scheduled_for_date', wrc.scheduled_for_date,
      'scheduled_weekday', wrc.scheduled_weekday_name_snapshot,
      'source_schedule_product_id', wrc.source_schedule_product_id,
      'route_code', wrc.route_code_snapshot,
      'route_display_name', wrc.route_display_name_snapshot,
      'route_color', wrc.route_color_snapshot
    )
    order by wrc.trace_code
  ), '[]'::jsonb)
  into v_trace_rows
  from public.sorting_wash_run_customers wrc
  where wrc.wash_run_id = v_wash_run_id;

  return v_result || jsonb_build_object(
    'unscheduled_customer_count', v_unscheduled_count,
    'early_customer_count', v_early_count,
    'trace_rows', v_trace_rows,
    'message', case
      when v_early_count > 0 and v_unscheduled_count > 0 then
        format(
          'Washing %s saved. %s customer(s) are work-ahead and %s customer(s) are off schedule.',
          v_result ->> 'wash_code',
          v_early_count,
          v_unscheduled_count
        )
      when v_early_count > 0 then
        format(
          'Washing %s saved. %s customer(s) belong to a future scheduled production day.',
          v_result ->> 'wash_code',
          v_early_count
        )
      when v_unscheduled_count > 0 then
        format(
          'Washing %s saved. %s customer(s) are outside the selected published schedule.',
          v_result ->> 'wash_code',
          v_unscheduled_count
        )
      else
        format('Washing %s saved successfully.', v_result ->> 'wash_code')
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Browser privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_sorting_staff_work_context_v2(text)
  from public, anon, authenticated;
revoke all on function public.set_sorting_mop_staff(text, uuid)
  from public, anon, authenticated;
revoke all on function public.get_sorting_customer_board_v2()
  from public, anon, authenticated;
revoke all on function public.get_sorting_washing_context_v2(text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_wash_run_v2(text, uuid, uuid, time, numeric, text, jsonb, text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_work_context_v2(text)
  to authenticated;
grant execute on function public.set_sorting_mop_staff(text, uuid)
  to authenticated;
grant execute on function public.get_sorting_customer_board_v2()
  to authenticated;
grant execute on function public.get_sorting_washing_context_v2(text)
  to authenticated;
grant execute on function public.save_sorting_wash_run_v2(text, uuid, uuid, time, numeric, text, jsonb, text)
  to authenticated;

comment on table public.sorting_daily_staff_modes is
  'Daily Sorting Actual sub-assignment. At most one staff member is explicitly MOP per Business Date and Shift; other active Sorting staff are treated as Clothes.';

comment on function public.get_sorting_customer_board_v2() is
  'Returns today and tomorrow published Clothes/MOP schedule rows with Route color, trolley quantity and washing completion status.';

comment on function public.save_sorting_wash_run_v2(text, uuid, uuid, time, numeric, text, jsonb, text) is
  'Records a washer load while preserving the explicitly selected customer scheduled production date. A tomorrow customer washed today is EARLY, never silently UNSCHEDULED.';

commit;
