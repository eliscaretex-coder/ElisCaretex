-- Validation for 202610220004_customer_kg_estimates_planner_fix.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(2);

select ok(
  (select 'enable_nestloop=off' = any(p.proconfig) from pg_proc p
   where p.oid='public.customer_kg_estimates(date,uuid)'::regprocedure),
  'customer_kg_estimates runs without nested loops');

create temporary table t_timing on commit drop as
with t0 as (select clock_timestamp() s), run as (
  select count(*) n from public.customer_kg_estimates(current_date), t0
)
select extract(epoch from clock_timestamp()-(select s from t0))*1000 ms from run;
select cmp_ok((select ms from t_timing)::numeric, '<', 800::numeric, 'customer_kg_estimates answers in under 0.8 s');

select * from finish();
rollback;
