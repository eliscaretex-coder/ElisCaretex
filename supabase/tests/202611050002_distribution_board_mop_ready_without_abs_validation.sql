-- Validation for 202611050002_distribution_board_mop_ready_without_abs.sql (pgTAP, no data written).
-- Compares the Distribution Daily board with the Production Tracker for the last two weeks.
begin;
select plan(12);

select has_function('public','get_production_tracker_v1',array['date'],'tracker v1 exists');
select has_function('public','get_production_tracker_v4',array['date'],'tracker v4 exists');
select has_function('public','distribution_source_stops',array['date','uuid'],'distribution_source_stops exists');
select ok(pg_get_functiondef('public.get_production_tracker_v1(date)'::regprocedure) like '%require_production_flow_read_role%','tracker checks permission');

-- ===== Checks =====================================================================
-- Read as a user who can open both the Production Tracker and Distribution.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code in ('PRODUCTION_TRACKER','DISTRIBUTION') and g.active and g.can_view
  group by g.auth_user_id having count(distinct g.module_code) = 2 limit 1),'role','authenticated')::text, true);

-- Delivery days of the last two weeks plus tomorrow, with each board customer's production day.
-- version_from: when the customer's schedule version starts. If it starts after the
-- production day (a schedule change between production and delivery), the two pages
-- legitimately read different versions; a customer only in the new version is left out.
create temporary table _board on commit drop as
select dd::date as delivery_date, s.customer_id::text as customer_id, s.route_id,
  (dd::date - ((extract(isodow from dd)::integer - d.production_weekday::integer + 7) % 7))::date as production_date,
  v.effective_from as version_from
from generate_series(public.current_business_date() - 14, public.current_business_date() + 1, interval '1 day') dd
cross join lateral public.distribution_source_stops(dd::date, null) s
join public.customer_schedule_days d on d.schedule_day_id = s.source_schedule_day_id
join public.customer_schedule_versions v on v.schedule_version_id = d.schedule_version_id
where extract(isodow from dd) <> 7;

create temporary table _tracker on commit drop as
select p.production_date, t.payload
from (select distinct production_date from _board) p
cross join lateral (select public.get_production_tracker_v4(p.production_date) as payload) t;

create temporary table _tracker_customers on commit drop as
select t.production_date, i->>'customer_id' as customer_id,
  min(i->>'customer_status') as customer_status, bool_or((i->>'scheduled')::boolean) as scheduled
from _tracker t cross join lateral jsonb_array_elements(t.payload->'items') i
group by 1, 2;

create temporary table _board_load on commit drop as
select dd.delivery_date, sum((r->>'scheduled_customers')::integer) as scheduled, sum((r->>'ready_customers')::integer) as ready
from (select distinct delivery_date from _board) dd
cross join lateral jsonb_array_elements(public.get_distribution_production_load(dd.delivery_date)->'routes') r
group by 1;

select is((select count(*) from (select delivery_date, customer_id from _board group by 1, 2 having count(*) > 1) x)::integer, 0,
  'the Daily board lists each customer once per delivery day');

select is((select count(*) from _board b left join _tracker_customers t
    on t.production_date = b.production_date and t.customer_id = b.customer_id
  where t.scheduled is distinct from true and b.version_from <= b.production_date)::integer, 0,
  'every Daily board customer is a scheduled customer in the Tracker on its production day');

select is((select count(*) from _board_load l
  where l.ready <> (select count(*) from _board b join _tracker_customers t
                      on t.production_date = b.production_date and t.customer_id = b.customer_id
                    where b.delivery_date = l.delivery_date and t.customer_status in ('TRACKER_OK', 'ABS_PENDING'))
    and not exists (select 1 from _board b left join _tracker_customers t
                      on t.production_date = b.production_date and t.customer_id = b.customer_id
                    where b.delivery_date = l.delivery_date and b.version_from > b.production_date
                      and t.scheduled is distinct from true))::integer, 0,
  'customers ready on the Daily board = customers Tracker OK or ABS pending in the Tracker, every day (MOP ready without ABS since 202611050002)');

select is((select count(*) from _tracker t
  where (t.payload->'summary'->>'tracker_ok')::integer
     <> (select count(*) from _tracker_customers c where c.production_date = t.production_date and c.customer_status = 'TRACKER_OK'))::integer, 0,
  'the Tracker OK KPI counts the same customers as the table');

select is((select count(*) from _tracker t cross join lateral jsonb_array_elements(t.payload->'items') i
  where i->>'product_code' = 'CLOTHES' and (i->>'finish_contribution_count')::integer > 0
    and i->>'product_status' <> 'TRACKER_OK')::integer, 0,
  'a Clothes stream with a Finish contribution is Tracker OK');

select ok(not has_function_privilege('anon','public.get_production_tracker_v4(date)','execute'), 'anon cannot read the tracker');
select ok(not has_function_privilege('authenticated','public.distribution_source_stops(date,uuid)','execute'), 'distribution_source_stops stays internal');

select is((select count(*) from _board_load l
  where (select sum((r->>'abs_pending_customers')::integer) from jsonb_array_elements(public.get_distribution_production_load(l.delivery_date)->'routes') r)
     <> (select count(*) from _board b
         where b.delivery_date = l.delivery_date
           and exists (select 1 from _tracker t cross join lateral jsonb_array_elements(t.payload->'items') i
                       where t.production_date = b.production_date and i->>'customer_id' = b.customer_id
                         and i->>'product_status' = 'ABS_PENDING')))::integer, 0,
  'MOP without ABS on the Daily board = customers with a MOP stream ABS pending in the Tracker');

select * from finish();
rollback;
