-- =====================================================================
-- ElisCaretex V2
-- End-of-shift trolley check (Production Tracker)
--
-- Owner request 2026-11-04: at the end of every shift the supervisor, or a
-- person the supervisor chooses, walks the ready trolleys with a phone and
-- checks each customer of the production list (normally today's list, which is
-- delivered tomorrow; another day when production is late or ahead):
--   * the number of trolleys,
--   * that the clothes and the mops are in them,
--   * the empty trolley some customers must receive,
--   * production that is physically ready but was never recorded in the system.
-- Management must see whether the check was done, who did it, at what time and
-- what had to be corrected.
--
-- Model
--   production_trolley_checks       one check per production date + shift
--                                   (IN_PROGRESS -> COMPLETED). Started by the
--                                   first customer result, closed by "Finish check".
--   production_trolley_check_items  append-only customer results. The newest row
--                                   per customer is the current result; older rows
--                                   stay as history. Each row keeps a snapshot of
--                                   what the system expected at that moment.
--
-- Results: OK, CORRECTED (a problem was found and fixed on the spot), PROBLEM
-- (still open), NOT_READY (production of that customer is not finished yet).
--
-- Expected values come from get_production_tracker_v4 (the same rows as the
-- Production map), so the check never has its own copy of the schedule.
--
-- Access
--   read   : require_production_flow_read_role() (same as Production Tracker)
--   record : ADMIN, MANAGER, SUPERVISOR, FINISH_OPERATOR, MOP_OPERATOR or the
--            PRODUCTION_TRACKER / FINISH / MOP module with EDIT, personal account
--            only (production terminals cannot sign a check).
-- =====================================================================

-- 1. Tables ------------------------------------------------------------------

create table public.production_trolley_checks (
  trolley_check_id uuid primary key default gen_random_uuid(),
  business_date date not null,
  shift_code text not null
    constraint production_trolley_checks_shift_check check (shift_code in ('MORNING','EVENING')),
  status text not null default 'IN_PROGRESS'
    constraint production_trolley_checks_status_check check (status in ('IN_PROGRESS','COMPLETED')),
  started_at timestamptz not null default now(),
  started_by uuid not null default auth.uid(),
  started_by_name text not null,
  completed_at timestamptz,
  completed_by uuid,
  completed_by_name text,
  completion_note text
    constraint production_trolley_checks_note_check check (completion_note is null or char_length(completion_note) <= 1000),
  completion_summary jsonb,
  constraint production_trolley_checks_day_shift_key unique (business_date, shift_code),
  constraint production_trolley_checks_completed_check check (
    (status = 'IN_PROGRESS' and completed_at is null)
    or (status = 'COMPLETED' and completed_at is not null and completed_by is not null)
  )
);

create table public.production_trolley_check_items (
  check_item_id uuid primary key default gen_random_uuid(),
  trolley_check_id uuid not null references public.production_trolley_checks(trolley_check_id),
  customer_id uuid not null references public.customers(customer_id),
  customer_name_snapshot text not null,
  route_code_snapshot text,
  result text not null
    constraint production_trolley_check_items_result_check check (result in ('OK','CORRECTED','PROBLEM','NOT_READY')),
  issue_codes text[] not null default '{}'
    constraint production_trolley_check_items_issue_check check (
      issue_codes <@ array['TROLLEY_COUNT','CLOTHES_MISSING','MOP_MISSING','EMPTY_TROLLEY_MISSING','NOT_RECORDED','WRONG_TROLLEY_TYPE','OTHER']::text[]
    ),
  counted_trolleys integer
    constraint production_trolley_check_items_counted_check check (counted_trolleys is null or counted_trolleys between 0 and 99),
  counted_empty_trolleys integer
    constraint production_trolley_check_items_counted_empty_check check (counted_empty_trolleys is null or counted_empty_trolleys between 0 and 99),
  note text
    constraint production_trolley_check_items_note_check check (note is null or char_length(note) <= 500),
  expected_snapshot jsonb not null,
  recorded_at timestamptz not null default now(),
  recorded_by uuid not null default auth.uid(),
  recorded_by_name text not null,
  constraint production_trolley_check_items_issue_result_check check (
    (result in ('OK','NOT_READY') and cardinality(issue_codes) = 0)
    or (result in ('CORRECTED','PROBLEM') and cardinality(issue_codes) > 0)
  )
);

create index production_trolley_check_items_current_idx
  on public.production_trolley_check_items(trolley_check_id, customer_id, recorded_at desc);
create index production_trolley_checks_date_idx
  on public.production_trolley_checks(business_date desc);

alter table public.production_trolley_checks enable row level security;
alter table public.production_trolley_check_items enable row level security;
revoke all on public.production_trolley_checks from public, anon, authenticated;
revoke all on public.production_trolley_check_items from public, anon, authenticated;

create or replace function public.production_trolley_check_items_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = 'P0001',
    message = 'Trolley check results are append-only. Record a new result instead.';
end;
$$;
revoke all on function public.production_trolley_check_items_append_only() from public, anon, authenticated;

create trigger production_trolley_check_items_no_change
before update or delete on public.production_trolley_check_items
for each row execute function public.production_trolley_check_items_append_only();

-- A check can only move from IN_PROGRESS to COMPLETED, once, and is never deleted.
create or replace function public.production_trolley_checks_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using errcode = 'P0001', message = 'A trolley check cannot be deleted.';
  end if;
  if old.status = 'COMPLETED'
     or new.status <> 'COMPLETED'
     or new.trolley_check_id <> old.trolley_check_id
     or new.business_date <> old.business_date
     or new.shift_code <> old.shift_code
     or new.started_at <> old.started_at
     or new.started_by <> old.started_by
     or new.started_by_name <> old.started_by_name then
    raise exception using errcode = 'P0001', message = 'A completed trolley check cannot be changed.';
  end if;
  return new;
end;
$$;
revoke all on function public.production_trolley_checks_guard() from public, anon, authenticated;

create trigger production_trolley_checks_guard
before update or delete on public.production_trolley_checks
for each row execute function public.production_trolley_checks_guard();

-- 2. Access and helpers --------------------------------------------------------

create or replace function public.require_production_trolley_check_write_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;
  if exists(select 1 from public.production_station_devices d where d.device_auth_user_id = auth.uid() and d.active) then
    raise exception using errcode = '42501',
      message = 'A production terminal cannot sign the trolley check. Use your personal login.';
  end if;
  if not public.account_module_allowed(
    array['PRODUCTION_TRACKER','FINISH','MOP'], 'EDIT',
    array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR']
  ) then
    raise exception using errcode = '42501', message = 'Your role cannot record the end-of-shift trolley check.';
  end if;
end;
$$;
revoke all on function public.require_production_trolley_check_write_access() from public, anon;
grant execute on function public.require_production_trolley_check_write_access() to authenticated;

create or replace function public.production_trolley_check_can_write()
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_trolley_check_write_access();
  return true;
exception when others then
  return false;
end;
$$;
revoke all on function public.production_trolley_check_can_write() from public, anon, authenticated;

-- Production date and shift "now", same rule as Finish (03:00 rollover, evening
-- from the EVENING work profile / shift master, fallback 14:00).
create or replace function public.production_trolley_check_now_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_timezone text;
  v_rollover time;
  v_local timestamp;
  v_evening time;
begin
  select nullif(value_json #>> '{}','') into v_timezone from public.app_config where config_key = 'business_timezone';
  v_timezone := coalesce(v_timezone, 'Europe/Dublin');
  select nullif(value_json #>> '{}','')::time into v_rollover from public.app_config where config_key = 'evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover, time '03:00');
  v_local := now() at time zone v_timezone;

  if v_local::time < v_rollover then
    return jsonb_build_object('business_date', v_local::date - 1, 'shift_code', 'EVENING');
  end if;

  begin
    v_evening := nullif(public.production_roster_work_profile_context(v_local::date, 'EVENING') ->> 'default_start_time','')::time;
  exception when others then
    v_evening := null;
  end;
  if v_evening is null then
    select sh.start_time into v_evening from public.shifts sh
    where sh.shift_code = 'EVENING' and sh.active and sh.deleted_at is null limit 1;
  end if;
  v_evening := coalesce(v_evening, time '14:00');

  return jsonb_build_object(
    'business_date', v_local::date,
    'shift_code', case when v_local::time >= v_evening then 'EVENING' else 'MORNING' end
  );
end;
$$;
revoke all on function public.production_trolley_check_now_context() from public, anon, authenticated;

-- What the system expects for every customer of one production date, built from
-- the Production Tracker rows (Clothes + MOP merged per customer).
create or replace function public.production_trolley_check_expected(p_business_date date)
returns table (
  customer_id uuid,
  customer_name text,
  route_code text,
  route_display_name text,
  route_color text,
  production_order integer,
  scheduled boolean,
  expected jsonb
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_tracker jsonb;
begin
  v_tracker := public.get_production_tracker_v4(p_business_date);

  return query
  with items as (
    select i
    from jsonb_array_elements(coalesce(v_tracker->'items','[]'::jsonb)) i
    where nullif(i->>'customer_id','') is not null
  ), req as (
    select (x.i->>'customer_id')::uuid cid,
      upper(coalesce(r->>'display_code', r->>'trolley_type_code', '?')) type_code,
      coalesce((r->>'empty_trolley')::boolean, false) is_empty,
      coalesce((r->>'quantity')::integer, 0) qty
    from items x, jsonb_array_elements(coalesce(x.i->'planned_trolley_requirements','[]'::jsonb)) r
  ), req_types as (
    select cid, is_empty, type_code, sum(qty)::integer qty from req group by cid, is_empty, type_code
  ), recorded as (
    select distinct (x.i->>'customer_id')::uuid cid, btrim(t->>'trolley_code') code
    from items x,
      jsonb_array_elements(coalesce(x.i->'lifecycle_trolleys','[]'::jsonb) || coalesce(x.i->'mop_trolleys','[]'::jsonb)) t
    where nullif(btrim(t->>'trolley_code'),'') is not null
  ), per_customer as (
    select (x.i->>'customer_id')::uuid cid,
      max(x.i->>'customer_name') cname,
      max(x.i->>'route_code') rcode,
      max(x.i->>'route_display_name') rname,
      max(x.i->>'route_color') rcolor,
      min(nullif(x.i->>'production_order','')::integer) porder,
      bool_or(coalesce((x.i->>'scheduled')::boolean, false)) sched,
      bool_or(upper(x.i->>'product_code') = 'CLOTHES') has_clothes,
      bool_or(upper(x.i->>'product_code') = 'MOP') has_mop,
      bool_or(upper(x.i->>'product_code') = 'CLOTHES' and coalesce((x.i->>'finish_contribution_count')::integer,0) > 0) clothes_recorded,
      bool_or(upper(x.i->>'product_code') = 'MOP' and nullif(x.i->>'mop_production_batch_id','') is not null) mop_recorded,
      sum(case when upper(x.i->>'product_code') = 'CLOTHES' then coalesce((x.i->>'processed_quantity_kg')::numeric,0) else 0 end) clothes_kg
    from items x
    group by 1
  )
  select pc.cid, pc.cname, pc.rcode, pc.rname, pc.rcolor, pc.porder, pc.sched,
    jsonb_build_object(
      'has_clothes', pc.has_clothes,
      'has_mop', pc.has_mop,
      'clothes_recorded', pc.clothes_recorded,
      'mop_recorded', pc.mop_recorded,
      'clothes_kg', round(pc.clothes_kg, 2),
      'planned_trolleys', coalesce((select sum(rt.qty) from req_types rt where rt.cid = pc.cid and not rt.is_empty), 0),
      'planned_empty_trolleys', coalesce((select sum(rt.qty) from req_types rt where rt.cid = pc.cid and rt.is_empty), 0),
      'planned_types', coalesce((select jsonb_agg(jsonb_build_object('type', rt.type_code, 'quantity', rt.qty) order by rt.type_code)
                                 from req_types rt where rt.cid = pc.cid and not rt.is_empty and rt.qty > 0), '[]'::jsonb),
      'planned_empty_types', coalesce((select jsonb_agg(jsonb_build_object('type', rt.type_code, 'quantity', rt.qty) order by rt.type_code)
                                 from req_types rt where rt.cid = pc.cid and rt.is_empty and rt.qty > 0), '[]'::jsonb),
      'recorded_trolleys', coalesce((select jsonb_agg(rc.code order by rc.code) from recorded rc where rc.cid = pc.cid), '[]'::jsonb)
    )
  from per_customer pc;
end;
$$;
revoke all on function public.production_trolley_check_expected(date) from public, anon, authenticated;

create or replace function public.production_trolley_check_summary(p_trolley_check_id uuid, p_business_date date)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  with cur as (
    select distinct on (i.customer_id) i.customer_id, i.result, i.issue_codes
    from public.production_trolley_check_items i
    where i.trolley_check_id = p_trolley_check_id
    order by i.customer_id, i.recorded_at desc, i.check_item_id desc
  ), expected as (
    select e.customer_id from public.production_trolley_check_expected(p_business_date) e
  )
  select jsonb_build_object(
    'customers', (select count(*) from expected),
    'checked', (select count(*) from cur),
    'ok', (select count(*) from cur where result = 'OK'),
    'corrected', (select count(*) from cur where result = 'CORRECTED'),
    'problem', (select count(*) from cur where result = 'PROBLEM'),
    'not_ready', (select count(*) from cur where result = 'NOT_READY'),
    'not_checked', (select count(*) from expected e where not exists(select 1 from cur c where c.customer_id = e.customer_id)),
    'not_recorded', (select count(*) from cur where 'NOT_RECORDED' = any(issue_codes))
  );
$$;
revoke all on function public.production_trolley_check_summary(uuid, date) from public, anon, authenticated;

-- 3. Read: the check screen -----------------------------------------------------

create or replace function public.get_production_trolley_check_v1(
  p_business_date date default null,
  p_shift_code text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_now jsonb;
  v_date date;
  v_shift text;
  v_check public.production_trolley_checks%rowtype;
  v_customers jsonb;
  v_day_checks jsonb;
begin
  perform public.require_production_flow_read_role();

  v_now := public.production_trolley_check_now_context();
  v_date := coalesce(p_business_date, (v_now->>'business_date')::date);
  v_shift := upper(coalesce(nullif(btrim(p_shift_code),''), v_now->>'shift_code'));
  if v_shift not in ('MORNING','EVENING') then
    raise exception using errcode = '22023', message = 'Choose the Morning or Evening shift.';
  end if;

  select * into v_check from public.production_trolley_checks c
  where c.business_date = v_date and c.shift_code = v_shift;

  with cur as (
    select distinct on (i.customer_id) i.*
    from public.production_trolley_check_items i
    where i.trolley_check_id = v_check.trolley_check_id
    order by i.customer_id, i.recorded_at desc, i.check_item_id desc
  ), counts as (
    select i.customer_id, count(*)::integer n
    from public.production_trolley_check_items i
    where i.trolley_check_id = v_check.trolley_check_id
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'customer_id', e.customer_id,
      'customer_name', e.customer_name,
      'route_code', e.route_code,
      'route_display_name', e.route_display_name,
      'route_color', e.route_color,
      'production_order', e.production_order,
      'scheduled', e.scheduled,
      'expected', e.expected,
      'current', case when c.check_item_id is null then null else jsonb_build_object(
        'result', c.result,
        'issue_codes', to_jsonb(c.issue_codes),
        'counted_trolleys', c.counted_trolleys,
        'counted_empty_trolleys', c.counted_empty_trolleys,
        'note', c.note,
        'recorded_at', c.recorded_at,
        'recorded_by_name', c.recorded_by_name,
        'revisions', coalesce(n.n, 1)
      ) end
    ) order by (not e.scheduled), (e.production_order is null), e.production_order, e.customer_name), '[]'::jsonb)
  into v_customers
  from public.production_trolley_check_expected(v_date) e
  left join cur c on c.customer_id = e.customer_id
  left join counts n on n.customer_id = e.customer_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'shift_code', c.shift_code, 'status', c.status,
      'started_at', c.started_at, 'started_by_name', c.started_by_name,
      'completed_at', c.completed_at, 'completed_by_name', c.completed_by_name
    ) order by c.shift_code desc), '[]'::jsonb)
  into v_day_checks
  from public.production_trolley_checks c
  where c.business_date = v_date;

  return jsonb_build_object(
    'schema_version', 'PRODUCTION_TROLLEY_CHECK_V1',
    'business_date', v_date,
    'shift_code', v_shift,
    'current_business_date', v_now->>'business_date',
    'current_shift_code', v_now->>'shift_code',
    'can_record', public.production_trolley_check_can_write(),
    'check', case when v_check.trolley_check_id is null then null else jsonb_build_object(
      'trolley_check_id', v_check.trolley_check_id,
      'status', v_check.status,
      'started_at', v_check.started_at,
      'started_by_name', v_check.started_by_name,
      'completed_at', v_check.completed_at,
      'completed_by_name', v_check.completed_by_name,
      'completion_note', v_check.completion_note
    ) end,
    'day_checks', v_day_checks,
    'customers', v_customers,
    'generated_at', now()
  );
end;
$$;
revoke all on function public.get_production_trolley_check_v1(date, text) from public, anon;
grant execute on function public.get_production_trolley_check_v1(date, text) to authenticated;

-- 4. Write: one customer result --------------------------------------------------

create or replace function public.record_production_trolley_check_item(
  p_business_date date,
  p_shift_code text,
  p_customer_id uuid,
  p_result text,
  p_issue_codes text[] default '{}',
  p_counted_trolleys integer default null,
  p_counted_empty_trolleys integer default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift text := upper(btrim(coalesce(p_shift_code,'')));
  v_result text := upper(btrim(coalesce(p_result,'')));
  v_issues text[];
  v_name text;
  v_check public.production_trolley_checks%rowtype;
  v_expected record;
  v_today date;
begin
  perform public.require_production_trolley_check_write_access();
  perform public.require_production_flow_read_role();

  if p_business_date is null then
    raise exception using errcode = '22023', message = 'Choose the production date.';
  end if;
  v_today := (public.production_trolley_check_now_context()->>'business_date')::date;
  if p_business_date < v_today - 7 or p_business_date > v_today + 7 then
    raise exception using errcode = '22023', message = 'The production date must be within 7 days of today.';
  end if;
  if v_shift not in ('MORNING','EVENING') then
    raise exception using errcode = '22023', message = 'Choose the Morning or Evening shift.';
  end if;
  if v_result not in ('OK','CORRECTED','PROBLEM','NOT_READY') then
    raise exception using errcode = '22023', message = 'Choose a valid result.';
  end if;

  select coalesce(array_agg(distinct upper(btrim(x))) filter (where nullif(btrim(x),'') is not null), '{}')
  into v_issues from unnest(coalesce(p_issue_codes,'{}'::text[])) x;
  if v_result in ('OK','NOT_READY') then
    v_issues := '{}';
  elsif cardinality(v_issues) = 0 then
    raise exception using errcode = '22023', message = 'Choose what was wrong.';
  end if;
  if not v_issues <@ array['TROLLEY_COUNT','CLOTHES_MISSING','MOP_MISSING','EMPTY_TROLLEY_MISSING','NOT_RECORDED','WRONG_TROLLEY_TYPE','OTHER']::text[] then
    raise exception using errcode = '22023', message = 'Unknown problem type.';
  end if;
  if 'OTHER' = any(v_issues) and nullif(btrim(coalesce(p_note,'')),'') is null then
    raise exception using errcode = '22023', message = 'Write what was wrong in the note.';
  end if;
  if char_length(coalesce(p_note,'')) > 500 then
    raise exception using errcode = '22023', message = 'The note cannot be longer than 500 characters.';
  end if;

  select e.* into v_expected
  from public.production_trolley_check_expected(p_business_date) e
  where e.customer_id = p_customer_id;
  if v_expected.customer_id is null then
    raise exception using errcode = 'P0002', message = 'This customer is not on the production list of that day.';
  end if;

  v_name := coalesce(nullif(public.get_current_account_access()->>'display_name',''), 'Signed in user');

  insert into public.production_trolley_checks (business_date, shift_code, started_by_name)
  values (p_business_date, v_shift, v_name)
  on conflict (business_date, shift_code) do nothing;

  select * into v_check from public.production_trolley_checks
  where business_date = p_business_date and shift_code = v_shift
  for update;

  if v_check.status = 'COMPLETED' then
    raise exception using errcode = '22023',
      message = format('The %s check of this day was already finished by %s.', initcap(v_shift), v_check.completed_by_name);
  end if;

  insert into public.production_trolley_check_items (
    trolley_check_id, customer_id, customer_name_snapshot, route_code_snapshot,
    result, issue_codes, counted_trolleys, counted_empty_trolleys, note,
    expected_snapshot, recorded_by_name
  ) values (
    v_check.trolley_check_id, p_customer_id, v_expected.customer_name, v_expected.route_code,
    v_result, v_issues,
    case when v_result = 'NOT_READY' then null else coalesce(p_counted_trolleys, (v_expected.expected->>'planned_trolleys')::integer) end,
    case when v_result = 'NOT_READY' then null else coalesce(p_counted_empty_trolleys, (v_expected.expected->>'planned_empty_trolleys')::integer) end,
    nullif(btrim(p_note),''),
    v_expected.expected, v_name
  );

  -- No day summary here: it would rebuild the whole Production Tracker on every tap.
  -- The screen updates its own counters; completion and history compute the summary.
  return jsonb_build_object(
    'trolley_check_id', v_check.trolley_check_id,
    'customer_id', p_customer_id,
    'result', v_result,
    'issue_codes', to_jsonb(v_issues),
    'recorded_at', now(),
    'recorded_by_name', v_name
  );
end;
$$;
revoke all on function public.record_production_trolley_check_item(date, text, uuid, text, text[], integer, integer, text) from public, anon;
grant execute on function public.record_production_trolley_check_item(date, text, uuid, text, text[], integer, integer, text) to authenticated;

-- 5. Write: finish the check -------------------------------------------------------

create or replace function public.complete_production_trolley_check(
  p_trolley_check_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_check public.production_trolley_checks%rowtype;
  v_summary jsonb;
  v_name text;
begin
  perform public.require_production_trolley_check_write_access();
  perform public.require_production_flow_read_role();

  if char_length(coalesce(p_note,'')) > 1000 then
    raise exception using errcode = '22023', message = 'The note cannot be longer than 1000 characters.';
  end if;

  select * into v_check from public.production_trolley_checks
  where trolley_check_id = p_trolley_check_id for update;
  if v_check.trolley_check_id is null then
    raise exception using errcode = 'P0002', message = 'Trolley check was not found.';
  end if;
  if v_check.status = 'COMPLETED' then
    raise exception using errcode = '22023', message = 'This trolley check was already finished.';
  end if;

  v_summary := public.production_trolley_check_summary(v_check.trolley_check_id, v_check.business_date);
  if (v_summary->>'not_checked')::integer > 0 and nullif(btrim(coalesce(p_note,'')),'') is null then
    raise exception using errcode = '22023',
      message = format('%s customer(s) were not checked. Write a note saying why before finishing.', v_summary->>'not_checked');
  end if;

  v_name := coalesce(nullif(public.get_current_account_access()->>'display_name',''), 'Signed in user');

  update public.production_trolley_checks
  set status = 'COMPLETED', completed_at = now(), completed_by = auth.uid(), completed_by_name = v_name,
      completion_note = nullif(btrim(p_note),''), completion_summary = v_summary
  where trolley_check_id = v_check.trolley_check_id;

  return jsonb_build_object('trolley_check_id', v_check.trolley_check_id, 'status', 'COMPLETED', 'summary', v_summary);
end;
$$;
revoke all on function public.complete_production_trolley_check(uuid, text) from public, anon;
grant execute on function public.complete_production_trolley_check(uuid, text) to authenticated;

-- 6. Read: management history -------------------------------------------------------
-- One row per production day (Monday to Saturday) and shift in the period, so a
-- missing check shows as NOT_DONE. Problems and corrections are listed per check.

create or replace function public.get_production_trolley_check_history_v1(
  p_date_from date default null,
  p_date_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date;
  v_from date;
  v_to date;
  v_rows jsonb;
begin
  perform public.require_production_flow_read_role();

  v_today := (public.production_trolley_check_now_context()->>'business_date')::date;
  v_to := coalesce(p_date_to, v_today);
  v_from := coalesce(p_date_from, v_to - 13);
  if v_from > v_to then
    raise exception using errcode = '22023', message = 'The start date must be on or before the end date.';
  end if;
  if v_to - v_from > 62 then
    raise exception using errcode = '22023', message = 'Choose a period of 63 days or fewer.';
  end if;

  with slots as (
    select d::date business_date, s.shift_code
    from generate_series(v_from, v_to, interval '1 day') d
    cross join (values ('MORNING'),('EVENING')) s(shift_code)
    where extract(isodow from d) <> 7
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'business_date', sl.business_date,
      'shift_code', sl.shift_code,
      'status', coalesce(c.status, 'NOT_DONE'),
      'trolley_check_id', c.trolley_check_id,
      'started_at', c.started_at,
      'started_by_name', c.started_by_name,
      'completed_at', c.completed_at,
      'completed_by_name', c.completed_by_name,
      'completion_note', c.completion_note,
      'summary', case
        when c.trolley_check_id is null then null
        when c.status = 'COMPLETED' then c.completion_summary
        else public.production_trolley_check_summary(c.trolley_check_id, c.business_date) end,
      'checked_by', coalesce((select jsonb_agg(distinct i.recorded_by_name) from public.production_trolley_check_items i
                              where i.trolley_check_id = c.trolley_check_id), '[]'::jsonb),
      'findings', coalesce((
        select jsonb_agg(jsonb_build_object(
            'customer_name', f.customer_name_snapshot,
            'route_code', f.route_code_snapshot,
            'result', f.result,
            'issue_codes', to_jsonb(f.issue_codes),
            'counted_trolleys', f.counted_trolleys,
            'counted_empty_trolleys', f.counted_empty_trolleys,
            'planned_trolleys', f.expected_snapshot->'planned_trolleys',
            'planned_empty_trolleys', f.expected_snapshot->'planned_empty_trolleys',
            'note', f.note,
            'recorded_at', f.recorded_at,
            'recorded_by_name', f.recorded_by_name
          ) order by f.recorded_at)
        from (
          select distinct on (i.customer_id) i.*
          from public.production_trolley_check_items i
          where i.trolley_check_id = c.trolley_check_id
          order by i.customer_id, i.recorded_at desc, i.check_item_id desc
        ) f
        where f.result in ('CORRECTED','PROBLEM')
      ), '[]'::jsonb)
    ) order by sl.business_date desc, sl.shift_code desc), '[]'::jsonb)
  into v_rows
  from slots sl
  left join public.production_trolley_checks c
    on c.business_date = sl.business_date and c.shift_code = sl.shift_code;

  return jsonb_build_object(
    'schema_version', 'PRODUCTION_TROLLEY_CHECK_HISTORY_V1',
    'date_from', v_from,
    'date_to', v_to,
    'rows', v_rows
  );
end;
$$;
revoke all on function public.get_production_trolley_check_history_v1(date, date) from public, anon;
grant execute on function public.get_production_trolley_check_history_v1(date, date) to authenticated;

comment on table public.production_trolley_checks is
  'End-of-shift trolley check per production date and shift (who started and finished it, when, summary).';
comment on table public.production_trolley_check_items is
  'Append-only customer results of the end-of-shift trolley check, with a snapshot of what the system expected.';
