-- Validation for 202610220005_customer_kg_estimate_weekly_snapshot.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(9);

select has_table('public','customer_kg_estimate_snapshot','snapshot table exists');
select ok((select relrowsecurity from pg_class where oid='public.customer_kg_estimate_snapshot'::regclass),'snapshot table has RLS enabled');
select ok(not has_table_privilege('authenticated','public.customer_kg_estimate_snapshot','select'),'authenticated cannot read the snapshot table directly');
select ok(not has_function_privilege('authenticated','public.refresh_customer_kg_estimate_snapshot()','execute'),'authenticated cannot call the internal refresh');
select ok(not has_function_privilege('anon','public.refresh_customer_kg_estimates_v1()','execute'),'anon cannot call the manual refresh');
select ok(exists(select 1 from cron.job where jobname='customer-kg-estimates-weekly-refresh' and schedule='0 5 * * 0'),'weekly refresh runs on Sunday 05:00 UTC');
select ok((select max(refreshed_for) from public.customer_kg_estimate_snapshot) is not null,'snapshot is filled');

-- Stored and live estimates agree for a date on or after the snapshot date.
select is(
  (select count(*)::integer from (
    (select * from public.customer_kg_estimates(current_date+3,null)
     except select * from public.customer_kg_estimates_live(current_date+3,null))
    union all
    (select * from public.customer_kg_estimates_live(current_date+3,null)
     except select * from public.customer_kg_estimates(current_date+3,null))
  ) x),
  0,'stored estimates match the live calculation');

-- A role without ADMIN or MANAGER cannot refresh on demand.
select set_config('request.jwt.claims',json_build_object('sub',(
  select d.device_auth_user_id from public.production_station_devices d where d.active limit 1
),'role','authenticated')::text,true);
select throws_ok('select public.refresh_customer_kg_estimates_v1()','42501',null,'a production terminal cannot refresh estimates');

select * from finish();
rollback;
