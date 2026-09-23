-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080009_sorting_v2_washing_and_trace_foundation.sql
-- Purpose:
--   * structured washer master;
--   * immutable Washing load ID;
--   * one trace row per customer inside the load;
--   * published Customer Schedule snapshot when applicable;
--   * controlled read/save RPCs for the Sorting workstation.
--
-- Trace model:
--   inbound trolley lifecycle -> customer/date context -> washing trace
--   -> future Finish/MOP record -> outbound trolley lifecycle.
--
-- Exact item-level inbound-trolley-to-wash lineage is NOT invented unless a
-- later explicit operational scan/link captures it.
-- =====================================================================

begin;

create table if not exists public.sorting_washers (
  washer_id uuid primary key default gen_random_uuid(),
  washer_code text not null unique,
  washer_name text not null,
  capacity_kg numeric(10,2) not null,
  category text,
  active boolean not null default true,
  sort_order integer not null default 0,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  constraint sorting_washers_capacity_check check (capacity_kg > 0)
);

insert into public.sorting_washers
  (washer_code, washer_name, capacity_kg, category, active, sort_order, metadata)
values
  ('WA01', 'WA 01 [90KG] CLOTHES',      90,  'CLOTHES',   true, 10, '{"source":"LEGACY_SORTING_REFERENCE"}'),
  ('WA03', 'WA 03 [28KG] ALGINATE',     28,  'ALGINATE',  true, 20, '{"source":"LEGACY_SORTING_REFERENCE"}'),
  ('WA04', 'WA 04 [90KG] CLOTHES',      90,  'CLOTHES',   true, 30, '{"source":"LEGACY_SORTING_REFERENCE"}'),
  ('WA07', 'WA 07 [90KG] CLOTHES',      90,  'CLOTHES',   true, 40, '{"source":"LEGACY_SORTING_REFERENCE"}'),
  ('WA08', 'WA 08 [100KG] HOUSEHOLD',  100,  'HOUSEHOLD', true, 50, '{"source":"LEGACY_SORTING_REFERENCE"}'),
  ('WA09', 'WA 09 [60KG] HOUSEHOLD',    60,  'HOUSEHOLD', true, 60, '{"source":"LEGACY_SORTING_REFERENCE"}')
on conflict (washer_code) do nothing;

create table if not exists public.sorting_wash_runs (
  wash_run_id uuid primary key default gen_random_uuid(),
  wash_code text not null unique,
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  washer_id uuid not null references public.sorting_washers(washer_id) on delete restrict,
  washer_code_snapshot text not null,
  washer_name_snapshot text not null,
  washer_capacity_kg_snapshot numeric(10,2) not null,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  operator_name_snapshot text not null,
  wash_type text not null,
  started_at timestamptz not null,
  registered_at timestamptz not null default now(),
  total_weight_kg numeric(12,2) not null,
  status text not null default 'RECORDED',
  notes text,
  source_application text not null default 'SORTING_V2',
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,
  constraint sorting_wash_runs_type_check check (wash_type in ('CLOTHES','MOP','OTHERS')),
  constraint sorting_wash_runs_weight_check
    check (total_weight_kg > 0 and total_weight_kg <= washer_capacity_kg_snapshot),
  constraint sorting_wash_runs_status_check check (status in ('RECORDED','CANCELLED')),
  constraint sorting_wash_runs_notes_check check (notes is null or length(notes) <= 1000)
);

create table if not exists public.sorting_wash_run_customers (
  wash_run_customer_id uuid primary key default gen_random_uuid(),
  trace_code text not null unique,
  wash_run_id uuid not null references public.sorting_wash_runs(wash_run_id) on delete restrict,
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text not null,
  customer_name_snapshot text not null,
  wash_type_snapshot text not null,
  source_schedule_version_id uuid references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  source_schedule_day_id uuid references public.customer_schedule_days(schedule_day_id) on delete restrict,
  source_schedule_product_id uuid references public.customer_schedule_products(schedule_product_id) on delete restrict,
  production_order_snapshot integer,
  expected_kg_snapshot numeric(12,2),
  production_instructions_snapshot text,
  schedule_relation text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint sorting_wash_run_customers_type_check check (wash_type_snapshot in ('CLOTHES','MOP','OTHERS')),
  constraint sorting_wash_run_customers_relation_check
    check (schedule_relation in ('TODAY','UNSCHEDULED','NOT_APPLICABLE')),
  constraint sorting_wash_run_customer_unique unique (wash_run_id, customer_id)
);

create index if not exists sorting_wash_runs_business_idx
  on public.sorting_wash_runs (business_date desc, shift_id, started_at desc);
create index if not exists sorting_wash_runs_washer_idx
  on public.sorting_wash_runs (washer_id, started_at desc)
  where status = 'RECORDED';
create index if not exists sorting_wash_run_customers_customer_idx
  on public.sorting_wash_run_customers (customer_id, created_at desc);

alter table public.sorting_washers enable row level security;
alter table public.sorting_wash_runs enable row level security;
alter table public.sorting_wash_run_customers enable row level security;

revoke all on table public.sorting_washers from public, anon, authenticated;
revoke all on table public.sorting_wash_runs from public, anon, authenticated;
revoke all on table public.sorting_wash_run_customers from public, anon, authenticated;

create or replace function public.get_sorting_washing_context(
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
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_sorting_context jsonb;
  v_washers jsonb;
  v_today_customers jsonb;
  v_all_customers jsonb;
  v_recent_washes jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  v_sorting_context := public.get_sorting_daily_context(v_business_date, v_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'washer_id', w.washer_id,
      'washer_code', w.washer_code,
      'washer_name', w.washer_name,
      'capacity_kg', w.capacity_kg,
      'category', w.category
    ) order by w.sort_order, w.washer_code
  ), '[]'::jsonb)
  into v_washers
  from public.sorting_washers w
  where w.active and w.deleted_at is null;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', q.customer_id,
      'customer_code', q.customer_code,
      'customer_name', q.customer_name,
      'product_code', q.product_code,
      'production_order', q.production_order,
      'expected_kg', q.expected_kg,
      'production_instructions', q.production_instructions,
      'schedule_version_id', q.schedule_version_id,
      'schedule_day_id', q.schedule_day_id,
      'schedule_product_id', q.schedule_product_id,
      'wash_count', q.wash_count,
      'last_wash_code', q.last_wash_code,
      'last_wash_started_at', q.last_wash_started_at,
      'status', case when q.wash_count > 0 then 'WASHED' else 'PENDING' end
    )
    order by
      case q.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
      q.production_order nulls last,
      lower(q.customer_name),
      q.customer_code
  ), '[]'::jsonb)
  into v_today_customers
  from (
    select
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
      (
        select count(*)::integer
        from public.sorting_wash_run_customers wrc
        join public.sorting_wash_runs wr on wr.wash_run_id = wrc.wash_run_id
        where wrc.customer_id = c.customer_id
          and wr.business_date = v_business_date
          and wr.wash_type = pt.product_code
          and wr.status = 'RECORDED'
      ) wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2 on wr2.wash_run_id = wrc2.wash_run_id
        where wrc2.customer_id = c.customer_id
          and wr2.business_date = v_business_date
          and wr2.wash_type = pt.product_code
          and wr2.status = 'RECORDED'
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) last_wash_code,
      (
        select wr3.started_at
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3 on wr3.wash_run_id = wrc3.wash_run_id
        where wrc3.customer_id = c.customer_id
          and wr3.business_date = v_business_date
          and wr3.wash_type = pt.product_code
          and wr3.status = 'RECORDED'
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) last_wash_started_at
    from public.customer_schedule_versions csv
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active
     and c.deleted_at is null
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
     and pt.product_code in ('CLOTHES','MOP')
    where csv.status = 'PUBLISHED'
      and csv.effective_from <= v_business_date
      and (csv.effective_until is null or csv.effective_until >= v_business_date)
  ) q;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', c.customer_id,
      'customer_code', c.customer_code,
      'customer_name', c.customer_name
    ) order by lower(c.customer_name), c.customer_code
  ), '[]'::jsonb)
  into v_all_customers
  from public.customers c
  where c.active and c.deleted_at is null;

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
    ) order by q.registered_at desc
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
            'schedule_relation', wrc.schedule_relation
          ) order by lower(wrc.customer_name_snapshot), wrc.customer_code_snapshot
        )
        from public.sorting_wash_run_customers wrc
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) customers
    from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.status = 'RECORDED'
    order by wr.registered_at desc
    limit 40
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift', v_sorting_context -> 'shift',
    'roster', v_sorting_context -> 'roster',
    'planned_staff', v_sorting_context -> 'planned_staff',
    'planned_staff_count', v_sorting_context -> 'planned_staff_count',
    'operator', v_sorting_context -> 'operator',
    'washers', v_washers,
    'today_customers', v_today_customers,
    'all_customers', v_all_customers,
    'recent_washes', v_recent_washes,
    'source', 'PUBLISHED_ROSTER_AND_PUBLISHED_CUSTOMER_SCHEDULE'
  );
end;
$$;

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

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_context -> 'planned_staff','[]'::jsonb)) staff_row
    where nullif(staff_row ->> 'staff_id','')::uuid = p_operator_staff_id
  ) then
    raise exception using
      errcode='22023',
      message=format('%s is not planned in Sorting for %s %s.',
        v_operator.display_name, v_business_date, v_shift.shift_name);
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

revoke all on function public.get_sorting_washing_context(text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_wash_run(text,uuid,uuid,time,numeric,text,uuid[],text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_washing_context(text)
  to authenticated;
grant execute on function public.save_sorting_wash_run(text,uuid,uuid,time,numeric,text,uuid[],text)
  to authenticated;

comment on table public.sorting_wash_runs is
  'One physical washer load. wash_code is the immutable operational trace identity.';
comment on table public.sorting_wash_run_customers is
  'One customer trace inside a washer load. Future Finish/MOP records should reference wash_run_customer_id.';
comment on function public.save_sorting_wash_run(text,uuid,uuid,time,numeric,text,uuid[],text) is
  'Current-day Sorting washing save. Supports two PCs with per-washer concurrency guard and creates per-customer production trace rows.';

commit;
