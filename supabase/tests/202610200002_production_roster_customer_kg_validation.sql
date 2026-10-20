begin;
select plan(4);

select has_function('public','get_production_roster_customer_kg',array['date','date'],'get_production_roster_customer_kg exists');
select ok(not has_function_privilege('anon','public.get_production_roster_customer_kg(date,date)','execute'),'anon cannot call get_production_roster_customer_kg');
select ok(pg_get_functiondef('public.get_production_roster_customer_kg(date,date)'::regprocedure) like '%require_production_roster_read_role%','get_production_roster_customer_kg checks roster read access');
select ok(pg_get_functiondef('public.get_production_roster_customer_kg(date,date)'::regprocedure) like '%customer_kg_estimates%','roster KG uses the automatic Expected KG');

select * from finish();
rollback;
