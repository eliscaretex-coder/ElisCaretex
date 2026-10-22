-- Store customer KG estimates and refresh them once a week (owner decision, 2026-10-22).
--
-- public.customer_kg_estimates(date, uuid) recalculated the estimate from the whole
-- production history on every call (about 1.9 s). Distribution, the weekly planner,
-- the production roster and production intelligence call it on every screen load.
--
-- Now:
--   - the original calculation is kept as public.customer_kg_estimates_live(date, uuid);
--   - public.customer_kg_estimate_snapshot holds its result for all customers, refreshed
--     every Sunday at 05:00 UTC (before the Sunday roster autopublish at 11/12 UTC) by
--     public.refresh_customer_kg_estimate_snapshot();
--   - public.customer_kg_estimates(date, uuid) keeps its signature and output. For a
--     reference date on or after the snapshot date it reads the stored estimates and
--     joins them to the schedule slots that are published for that date, so a new or
--     changed schedule still shows (as LEARNING until the next refresh). For an earlier
--     date (for example Customer KG history) it still calculates live.
--   - ADMIN and MANAGER can refresh on demand with public.refresh_customer_kg_estimates_v1().

alter function public.customer_kg_estimates(date, uuid) rename to customer_kg_estimates_live;
alter function public.customer_kg_estimates_live(date, uuid) set enable_nestloop = off;

create table public.customer_kg_estimate_snapshot (
  customer_id uuid not null references public.customers(customer_id),
  product_code text not null,
  production_weekday smallint not null,
  estimated_kg numeric,
  history_points integer not null,
  median_kg numeric,
  minimum_kg numeric,
  maximum_kg numeric,
  last_service_date date,
  last_service_kg numeric,
  carried_over_points integer not null,
  refreshed_for date not null,
  refreshed_at timestamptz not null default now(),
  primary key (customer_id, product_code, production_weekday)
);

alter table public.customer_kg_estimate_snapshot enable row level security;
revoke all on table public.customer_kg_estimate_snapshot from public, anon, authenticated;

create or replace function public.refresh_customer_kg_estimate_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date date := current_date;
  v_rows integer;
begin
  delete from public.customer_kg_estimate_snapshot where true;
  insert into public.customer_kg_estimate_snapshot(
    customer_id, product_code, production_weekday, estimated_kg, history_points,
    median_kg, minimum_kg, maximum_kg, last_service_date, last_service_kg,
    carried_over_points, refreshed_for, refreshed_at
  )
  select e.customer_id, e.product_code, e.production_weekday, e.estimated_kg, e.history_points,
    e.median_kg, e.minimum_kg, e.maximum_kg, e.last_service_date, e.last_service_kg,
    e.carried_over_points, v_date, now()
  from public.customer_kg_estimates_live(v_date, null) e;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('status','success','refreshed_for',v_date,'rows',v_rows);
end;
$$;

revoke all on function public.refresh_customer_kg_estimate_snapshot() from public, anon, authenticated;

create or replace function public.refresh_customer_kg_estimates_v1()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled()
     or not public.has_any_role(array['ADMIN','MANAGER']) then
    raise exception using errcode='42501', message='Your active role cannot refresh customer KG estimates.';
  end if;
  return public.refresh_customer_kg_estimate_snapshot();
end;
$$;

revoke all on function public.refresh_customer_kg_estimates_v1() from public, anon;
grant execute on function public.refresh_customer_kg_estimates_v1() to authenticated;

create or replace function public.customer_kg_estimates(p_reference_date date, p_customer_id uuid default null)
returns table(customer_id uuid, product_code text, production_weekday smallint, estimated_kg numeric,
  history_points integer, median_kg numeric, minimum_kg numeric, maximum_kg numeric,
  last_service_date date, last_service_kg numeric, carried_over_points integer, estimate_status text)
language plpgsql
stable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_snapshot_date date;
begin
  select max(s.refreshed_for) into v_snapshot_date from public.customer_kg_estimate_snapshot s;

  if v_snapshot_date is null or p_reference_date < v_snapshot_date then
    return query select * from public.customer_kg_estimates_live(p_reference_date, p_customer_id);
    return;
  end if;

  return query
  with slots as (
    select distinct v.customer_id, pt.product_code, d.production_weekday::smallint production_weekday
    from public.customer_schedule_versions v
    join public.customers c on c.customer_id=v.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code in ('CLOTHES','MOP')
    where v.status='PUBLISHED' and v.effective_from<=p_reference_date
      and (v.effective_until is null or v.effective_until>=p_reference_date)
      and (p_customer_id is null or v.customer_id=p_customer_id)
  )
  select sl.customer_id, sl.product_code, sl.production_weekday,
    s.estimated_kg, coalesce(s.history_points,0), s.median_kg, s.minimum_kg, s.maximum_kg,
    s.last_service_date, s.last_service_kg, coalesce(s.carried_over_points,0),
    case when coalesce(s.history_points,0)<3 then 'LEARNING'
         when s.last_service_date<p_reference_date-42 then 'STALE'
         else 'READY' end
  from slots sl
  left join public.customer_kg_estimate_snapshot s
    on s.customer_id=sl.customer_id and s.product_code=sl.product_code and s.production_weekday=sl.production_weekday;
end;
$$;

revoke all on function public.customer_kg_estimates(date, uuid) from public, anon, authenticated;

select public.refresh_customer_kg_estimate_snapshot();

do $$ begin
  if exists(select 1 from cron.job where jobname='customer-kg-estimates-weekly-refresh') then
    perform cron.unschedule('customer-kg-estimates-weekly-refresh');
  end if;
  perform cron.schedule('customer-kg-estimates-weekly-refresh','0 5 * * 0',$job$select public.refresh_customer_kg_estimate_snapshot();$job$);
end $$;
