-- =====================================================================
-- ElisCaretex V2
-- Customer Schedule: units check for customers with more than 2 trolleys
--
-- Owner request 2026-10-29: every customer whose schedule plans more than 2
-- trolleys on a day must have its units (subunits, see 202610290001) checked
-- trolley by trolley, for existing customers, new customers and every change
-- of the trolley quantities.
--
-- * customer_schedule_unit_checks: append-only record "the units of this
--   schedule were checked", with a signature of what was checked: per active
--   day the trolley rows (type, owner product, quantity, empty) and their
--   plates, plus the customer's active units in Customer Master.
-- * A schedule version is CHECKED while a check exists for the same customer
--   with the same signature. Changing a trolley quantity, a plate or the unit
--   list gives a new signature, so the schedule is TO_CHECK again. A change
--   that keeps trolleys and units (for example Expected KG) keeps the check.
-- * A version without any day above 2 trolleys is NOT_NEEDED.
-- * Nothing in a published schedule is changed by a check.
-- =====================================================================

-- 1. Table ----------------------------------------------------------------------

create table public.customer_schedule_unit_checks (
  unit_check_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id),
  schedule_version_id uuid not null
    references public.customer_schedule_versions(schedule_version_id),
  units_signature text not null,
  max_day_trolleys integer not null,
  note text
    constraint customer_schedule_unit_checks_note_check
    check (note is null or char_length(note) <= 500),
  source_application text not null default 'CUSTOMER_SCHEDULE_UI',
  checked_at timestamptz not null default now(),
  checked_by uuid default auth.uid()
);

create index customer_schedule_unit_checks_customer_idx
  on public.customer_schedule_unit_checks(customer_id, units_signature, checked_at desc);

alter table public.customer_schedule_unit_checks enable row level security;
revoke all on public.customer_schedule_unit_checks from public, anon, authenticated;

create or replace function public.customer_schedule_unit_checks_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'Units checks are append-only. Record a new check instead.';
end;
$$;

revoke all on function public.customer_schedule_unit_checks_append_only() from public, anon, authenticated;

create trigger customer_schedule_unit_checks_no_change
before update or delete on public.customer_schedule_unit_checks
for each row execute function public.customer_schedule_unit_checks_append_only();

-- 2. Internal: units check state of one schedule version -------------------------

create or replace function public.customer_schedule_units_check_state(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer_id uuid;
  v_status text;
  v_days jsonb;
  v_max integer;
  v_signature text;
  v_unit_count integer;
  v_trolleys_over integer;
  v_trolleys_with_units integer;
  v_check record;
begin
  select v.customer_id, v.status
  into v_customer_id, v_status
  from public.customer_schedule_versions v
  where v.schedule_version_id = p_schedule_version_id;

  if v_customer_id is null then
    return null;
  end if;

  -- Trolleys per active day, with the plates that carry a unit.
  with day_rows as (
    select
      d.schedule_day_id,
      d.production_weekday,
      coalesce(sum(r.quantity), 0)::integer as trolleys,
      coalesce(sum((
        select count(*)
        from public.customer_schedule_trolley_plates pl
        where pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
          and pl.plate_number <= r.quantity
          and cardinality(pl.subunit_ids) > 0
      )), 0)::integer as trolleys_with_units
    from public.customer_schedule_days d
    left join public.customer_schedule_trolley_requirements r
      on r.schedule_day_id = d.schedule_day_id
     and r.active = true
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
    group by d.schedule_day_id, d.production_weekday
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'production_weekday', production_weekday,
        'production_day', public.weekday_name(production_weekday),
        'trolley_count', trolleys,
        'trolleys_with_units', trolleys_with_units,
        'needs_check', trolleys > 2
      )
      order by production_weekday
    ), '[]'::jsonb),
    coalesce(max(trolleys), 0),
    coalesce(sum(trolleys) filter (where trolleys > 2), 0),
    coalesce(sum(trolleys_with_units) filter (where trolleys > 2), 0)
  into v_days, v_max, v_trolleys_over, v_trolleys_with_units
  from day_rows;

  select count(*)::integer
  into v_unit_count
  from public.customer_subunits su
  where su.customer_id = v_customer_id
    and su.active = true;

  -- What was checked: trolley rows and plates per day, and the unit list.
  select md5(jsonb_build_object(
    'days', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'weekday', d.production_weekday,
          'trolleys', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'type', tt.trolley_type_code,
                'owner', pt.product_code,
                'quantity', r.quantity,
                'empty', r.empty_trolley,
                'plates', coalesce((
                  select jsonb_agg(
                    jsonb_build_object('n', pl.plate_number, 'units', to_jsonb(pl.subunit_ids))
                    order by pl.plate_number
                  )
                  from public.customer_schedule_trolley_plates pl
                  where pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
                    and pl.plate_number <= r.quantity
                    and cardinality(pl.subunit_ids) > 0
                ), '[]'::jsonb)
              )
              order by tt.trolley_type_code, pt.product_code, r.quantity, r.empty_trolley
            )
            from public.customer_schedule_trolley_requirements r
            join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id
            join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
            join public.product_types pt on pt.product_type_id = p.product_type_id
            where r.schedule_day_id = d.schedule_day_id
              and r.active = true
          ), '[]'::jsonb)
        )
        order by d.production_weekday
      )
      from public.customer_schedule_days d
      where d.schedule_version_id = p_schedule_version_id
        and d.active = true
    ), '[]'::jsonb),
    'units', coalesce((
      select jsonb_agg(su.subunit_id order by su.subunit_id)
      from public.customer_subunits su
      where su.customer_id = v_customer_id
        and su.active = true
    ), '[]'::jsonb)
  )::text)
  into v_signature;

  select c.checked_at, c.checked_by, c.note, c.schedule_version_id
  into v_check
  from public.customer_schedule_unit_checks c
  where c.customer_id = v_customer_id
    and c.units_signature = v_signature
  order by c.checked_at desc
  limit 1;

  return jsonb_build_object(
    'schedule_version_id', p_schedule_version_id,
    'customer_id', v_customer_id,
    'version_status', v_status,
    'needed', v_max > 2,
    'status', case
      when v_max <= 2 then 'NOT_NEEDED'
      when v_check.checked_at is not null then 'CHECKED'
      else 'TO_CHECK'
    end,
    'max_day_trolleys', v_max,
    'unit_count', v_unit_count,
    'trolleys_on_checked_days', v_trolleys_over,
    'trolleys_with_units', v_trolleys_with_units,
    'days', v_days,
    'units_signature', v_signature,
    'checked_at', v_check.checked_at,
    'checked_by_name', case
      when v_check.checked_at is null then null
      else coalesce(public.production_roster_actor_name(v_check.checked_by, null), 'Unknown user')
    end,
    'check_note', v_check.note,
    'checked_on_version_id', v_check.schedule_version_id
  );
end;
$$;

revoke all on function public.customer_schedule_units_check_state(uuid) from public, anon, authenticated;

-- 3. Read and confirm ---------------------------------------------------------------

create or replace function public.get_customer_schedule_units_check(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_state jsonb;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to view customers.';
  end if;

  v_state := public.customer_schedule_units_check_state(p_schedule_version_id);

  if v_state is null then
    raise exception using errcode = 'P0002', message = 'Schedule version was not found.';
  end if;

  return v_state - 'units_signature';
end;
$$;

revoke all on function public.get_customer_schedule_units_check(uuid) from public, anon;
grant execute on function public.get_customer_schedule_units_check(uuid) to authenticated;

-- Confirms that the units of every trolley of a DRAFT or PUBLISHED version were
-- checked (assigned where needed, or the customer has none). Appends a check.
create or replace function public.confirm_customer_schedule_units(
  p_schedule_version_id uuid,
  p_note text default null,
  p_source_application text default 'CUSTOMER_SCHEDULE_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_state jsonb;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to change customers.';
  end if;

  if char_length(coalesce(p_note, '')) > 500 then
    raise exception using errcode = '22023', message = 'The note cannot be longer than 500 characters.';
  end if;

  v_state := public.customer_schedule_units_check_state(p_schedule_version_id);

  if v_state is null then
    raise exception using errcode = 'P0002', message = 'Schedule version was not found.';
  end if;

  if v_state ->> 'version_status' not in ('DRAFT', 'PUBLISHED') then
    raise exception using errcode = '22023', message = 'Only a draft or published schedule can be checked.';
  end if;

  if not (v_state ->> 'needed')::boolean then
    raise exception using errcode = '22023', message = 'No day of this schedule has more than 2 trolleys, so no units check is needed.';
  end if;

  insert into public.customer_schedule_unit_checks (
    customer_id,
    schedule_version_id,
    units_signature,
    max_day_trolleys,
    note,
    source_application
  )
  values (
    (v_state ->> 'customer_id')::uuid,
    p_schedule_version_id,
    v_state ->> 'units_signature',
    (v_state ->> 'max_day_trolleys')::integer,
    nullif(trim(p_note), ''),
    coalesce(nullif(trim(p_source_application), ''), 'CUSTOMER_SCHEDULE_UI')
  );

  return public.customer_schedule_units_check_state(p_schedule_version_id) - 'units_signature';
end;
$$;

revoke all on function public.confirm_customer_schedule_units(uuid, text, text) from public, anon;
grant execute on function public.confirm_customer_schedule_units(uuid, text, text) to authenticated;

-- Customer Master list: units check status of each active customer's schedule
-- in force today (only customers that need a check are listed).
create or replace function public.get_customer_units_check_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := public.current_business_date();
  v_items jsonb;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to view customers.';
  end if;

  with current_versions as (
    select distinct on (v.customer_id) v.customer_id, v.schedule_version_id
    from public.customer_schedule_versions v
    join public.customers c on c.customer_id = v.customer_id
    where c.active = true
      and c.deleted_at is null
      and v.status = 'PUBLISHED'
      and v.effective_from <= v_today
      and (v.effective_until is null or v.effective_until >= v_today)
    order by v.customer_id, v.effective_from desc, v.version_number desc
  ), states as (
    select public.customer_schedule_units_check_state(cv.schedule_version_id) as s
    from current_versions cv
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', s ->> 'customer_id',
      'schedule_version_id', s ->> 'schedule_version_id',
      'status', s ->> 'status',
      'max_day_trolleys', (s ->> 'max_day_trolleys')::integer,
      'unit_count', (s ->> 'unit_count')::integer,
      'trolleys_with_units', (s ->> 'trolleys_with_units')::integer,
      'trolleys_on_checked_days', (s ->> 'trolleys_on_checked_days')::integer
    )
  ), '[]'::jsonb)
  into v_items
  from states
  where (s ->> 'needed')::boolean;

  return jsonb_build_object(
    'business_date', v_today,
    'to_check_count', (select count(*) from jsonb_array_elements(v_items) i where i ->> 'status' = 'TO_CHECK'),
    'items', v_items
  );
end;
$$;

revoke all on function public.get_customer_units_check_overview() from public, anon;
grant execute on function public.get_customer_units_check_overview() to authenticated;

comment on table public.customer_schedule_unit_checks is
  'Append-only: the units of a schedule with more than 2 trolleys on a day were checked. Valid while trolleys, plates and units keep the same signature.';
comment on function public.confirm_customer_schedule_units(uuid, text, text) is
  'Customer Schedule: records that the units of every trolley were checked (CUSTOMERS:EDIT).';
