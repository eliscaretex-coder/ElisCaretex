begin;
select plan(16);

select has_function('public','customer_kg_service_history',array['date','uuid'],'customer_kg_service_history exists');
select has_function('public','customer_kg_estimates',array['date','uuid'],'customer_kg_estimates exists');
select has_function('public','get_customer_kg_estimates',array['date','uuid'],'get_customer_kg_estimates exists');

select ok(not has_function_privilege('authenticated','public.customer_kg_service_history(date,uuid)','execute'),'authenticated cannot call the internal service history');
select ok(not has_function_privilege('authenticated','public.customer_kg_estimates(date,uuid)','execute'),'authenticated cannot call the internal estimates');
select ok(not has_function_privilege('anon','public.get_customer_kg_estimates(date,uuid)','execute'),'anon cannot call get_customer_kg_estimates');
select ok(pg_get_functiondef('public.get_customer_kg_estimates(date,uuid)'::regprocedure) like '%require_any_customer_read_role%','get_customer_kg_estimates checks customer read roles');

select is(
  (select count(*) from public.customer_kg_service_history(public.current_business_date(),null)
   where extract(isodow from service_date)::integer<>production_weekday),
  0::bigint,'every service is credited to its scheduled production weekday');
select is(
  (select count(*) from public.customer_kg_estimates(public.current_business_date(),null)
   where estimated_kg is not null and history_points<3),
  0::bigint,'no automatic KG before three services');
select is(
  (select count(*) from public.customer_kg_estimates(public.current_business_date(),null)
   where estimated_kg is not null and (estimated_kg<minimum_kg-0.1 or estimated_kg>maximum_kg+0.1)),
  0::bigint,'capped average stays within the observed range');
select is(
  (select count(*) from public.customer_kg_estimates(public.current_business_date(),null) where history_points>8),
  0::bigint,'window uses at most eight services');

select ok(pg_get_functiondef('public.distribution_source_stops(date,uuid)'::regprocedure) like '%customer_kg_estimates%','Distribution stops use the automatic KG');
select ok(pg_get_functiondef('public.get_distribution_weekly_planner(date,smallint,text)'::regprocedure) like '%expected_kg_source%','Route customers expose the KG source');
select ok(pg_get_functiondef('public.get_customer_kg_history(uuid,date,date,integer)'::regprocedure) like '%customer_kg_estimates%','Schedule editor uses the automatic KG');
select ok(pg_get_functiondef('public.get_production_intelligence_forward_capacity(date,integer)'::regprocedure) like '%customer_kg_estimates%','Forward capacity uses the automatic KG');
select ok(pg_get_functiondef('public.get_production_roster_capacity_calendar(date,text)'::regprocedure) like '%customer_kg_estimates%','Leave capacity calendar uses the automatic KG');

select * from finish();
rollback;
