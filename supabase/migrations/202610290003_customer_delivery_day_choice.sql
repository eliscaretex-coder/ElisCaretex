-- =====================================================================
-- ElisCaretex V2
-- Customer Schedule: the delivery day can be chosen per production day
--
-- Owner decision 2026-10-29 ("Valer em tudo"): delivery is normally the day
-- after production (Saturday to Monday), but some customers are delivered two
-- or more days later. The delivery weekday chosen in the schedule now applies
-- everywhere the delivery date is used.
--
-- Until now:
-- * trigger customer_schedule_days_automatic_delivery_weekday overwrote
--   delivery_weekday with next_distribution_weekday(production_weekday), and
-- * production functions computed the delivery date as
--   next_distribution_business_date(production date).
--
-- Now:
-- * the trigger only fills an empty delivery_weekday with the next day, and
--   refuses a delivery on the production weekday itself;
-- * schedule_delivery_date(schedule day, production date) returns the first
--   date after production that falls on the day's delivery weekday (falls back
--   to the next-day rule when the day or its delivery weekday is unknown);
-- * customer_delivery_date(customer, production date) does the same from the
--   schedule version in force on that date;
-- * Finish (queue, cutoff, entry lock, delivery reconciliation), MOP
--   Production (due date, reconciliation, save), trolley custody planned
--   delivery and the Distribution planner/overview use them.
--
-- For every existing schedule the result is identical to before, because the
-- trigger had stored exactly the next-day weekday on every row.
--
-- Not changed on purpose: the integration.legacy_sync_* functions keep the
-- Apps Script next-day rule for the historical/legacy data they import, and
-- get_trolley_production_customers keeps its page-level default.
--
-- The production functions are patched in place from their live definitions
-- (section 4): every replacement must match the expected number of times or
-- the migration stops, so a definition that changed meanwhile is never
-- patched blindly.
-- =====================================================================

-- 1. Delivery date helpers ------------------------------------------------------

create or replace function public.schedule_delivery_date(
  p_schedule_day_id uuid,
  p_production_date date
)
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select case
    when p_production_date is null then null
    when d.delivery_weekday between 1 and 7 then
      p_production_date
      + (((d.delivery_weekday - extract(isodow from p_production_date)::integer + 6) % 7) + 1)
    else public.next_distribution_business_date(p_production_date)
  end
  from (select 1) one
  left join public.customer_schedule_days d
    on d.schedule_day_id = p_schedule_day_id;
$$;

revoke all on function public.schedule_delivery_date(uuid, date) from public, anon;
grant execute on function public.schedule_delivery_date(uuid, date) to authenticated;

create or replace function public.customer_delivery_date(
  p_customer_id uuid,
  p_production_date date
)
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select public.schedule_delivery_date(
    (
      select d.schedule_day_id
      from public.customer_schedule_versions v
      join public.customer_schedule_days d
        on d.schedule_version_id = v.schedule_version_id
       and d.active = true
       and d.production_weekday = extract(isodow from p_production_date)::smallint
      where v.customer_id = p_customer_id
        and v.status = 'PUBLISHED'
        and v.effective_from <= p_production_date
        and (v.effective_until is null or v.effective_until >= p_production_date)
      order by v.effective_from desc, v.version_number desc
      limit 1
    ),
    p_production_date
  );
$$;

revoke all on function public.customer_delivery_date(uuid, date) from public, anon;
grant execute on function public.customer_delivery_date(uuid, date) to authenticated;

comment on function public.schedule_delivery_date(uuid, date) is
  'Delivery date of a production date for a Customer Schedule day: the first later date on the day''s delivery weekday; next-day rule when unknown.';
comment on function public.customer_delivery_date(uuid, date) is
  'Delivery date of a customer''s production date, from the schedule version in force on that date.';

-- 2. The schedule keeps the chosen delivery weekday --------------------------------

create or replace function public.set_automatic_schedule_delivery_weekday()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- The next day (Saturday to Monday) is only the default.
  new.delivery_weekday := coalesce(
    new.delivery_weekday,
    public.next_distribution_weekday(new.production_weekday)
  );

  if new.delivery_weekday = new.production_weekday then
    raise exception using
      errcode = '22023',
      message = format(
        'Delivery on %s cannot be the production day itself. Choose a later delivery day.',
        public.weekday_name(new.production_weekday)
      );
  end if;

  return new;
end;
$$;

comment on function public.set_automatic_schedule_delivery_weekday() is
  'Customer Schedule days: delivery weekday defaults to the next distribution day and may be set later, never the production weekday.';

-- 3. Distribution planner and overview read the stored delivery weekday ------------
-- 4. Production functions use the schedule delivery date ---------------------------

do $patch$
declare
  v_patch record;
  v_definition text;
  v_count integer;
begin
  for v_patch in
    select *
    from (values
      -- Distribution
      ('public.get_customer_distribution_overview(uuid,date)'::regprocedure,
       'public.next_distribution_weekday(d.production_weekday)',
       'coalesce(d.delivery_weekday, public.next_distribution_weekday(d.production_weekday))', 2),
      ('public.get_distribution_weekly_planner(date,smallint,text)'::regprocedure,
       'public.next_distribution_weekday(d.production_weekday)',
       'coalesce(d.delivery_weekday, public.next_distribution_weekday(d.production_weekday))', 3),
      -- Finish
      ('public.get_finish_production_context(text,timestamptz)'::regprocedure,
       'public.next_distribution_business_date(p.scheduled_for_date)',
       'public.schedule_delivery_date(p.source_schedule_day_id, p.scheduled_for_date)', 3),
      ('public.get_finish_operational_queue_context(text,timestamptz)'::regprocedure,
       'public.next_distribution_business_date(pfi.scheduled_for_date)',
       'public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date)', 1),
      ('public.get_finish_delivery_reconciliation_context(timestamptz)'::regprocedure,
       'public.next_distribution_business_date(pfi.scheduled_for_date)',
       'public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date)', 3),
      ('public.finish_assert_entry_open(uuid,timestamptz)'::regprocedure,
       'public.next_distribution_business_date(v_flow.scheduled_for_date)',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, v_flow.scheduled_for_date)', 1),
      ('public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text)'::regprocedure,
       'public.next_distribution_business_date(v_flow.scheduled_for_date)',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, v_flow.scheduled_for_date)', 1),
      ('public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)'::regprocedure,
       'public.next_distribution_business_date(v_flow.scheduled_for_date)',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, v_flow.scheduled_for_date)', 1),
      ('public.assign_finish_trolley_to_flow(text,uuid,date,text)'::regprocedure,
       'public.next_distribution_business_date(v_flow.scheduled_for_date)',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, v_flow.scheduled_for_date)', 1),
      -- MOP Production
      ('public.get_sorting_mop_production_context(text,timestamptz)'::regprocedure,
       'public.next_distribution_business_date(coalesce(pfi.scheduled_for_date,pfi.opened_business_date))',
       'public.schedule_delivery_date(pfi.source_schedule_day_id, coalesce(pfi.scheduled_for_date,pfi.opened_business_date))', 1),
      ('public.record_sorting_mop_reconciliation(text,uuid,uuid,text,text)'::regprocedure,
       'public.next_distribution_business_date(coalesce(v_flow.scheduled_for_date,v_flow.opened_business_date))',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, coalesce(v_flow.scheduled_for_date,v_flow.opened_business_date))', 1),
      ('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)'::regprocedure,
       'public.next_distribution_business_date(v_base_date)',
       'public.schedule_delivery_date(v_flow.source_schedule_day_id, v_base_date)', 1),
      ('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)'::regprocedure,
       'public.next_distribution_business_date(coalesce(q.scheduled_for_date,q.opened_business_date))',
       'public.schedule_delivery_date(q.source_schedule_day_id, coalesce(q.scheduled_for_date,q.opened_business_date))', 1),
      -- Trolley custody from a production area
      ('public.assign_trolley_to_customer_from_production(text,uuid,date,text,text,text)'::regprocedure,
       'public.next_distribution_business_date(v_production_date)',
       'public.customer_delivery_date(p_customer_id, v_production_date)', 1)
    ) as patches(fn, old_text, new_text, expected)
  loop
    v_definition := pg_get_functiondef(v_patch.fn);
    v_count := (length(v_definition) - length(replace(v_definition, v_patch.old_text, '')))
      / length(v_patch.old_text);

    if v_count <> v_patch.expected then
      raise exception 'Delivery day patch: % has % occurrence(s) of "%", expected %.',
        v_patch.fn, v_count, v_patch.old_text, v_patch.expected;
    end if;

    execute replace(v_definition, v_patch.old_text, v_patch.new_text);
  end loop;
end;
$patch$;
