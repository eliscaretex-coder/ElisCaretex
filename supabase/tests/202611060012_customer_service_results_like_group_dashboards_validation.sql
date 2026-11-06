-- Validation for 202611060012_customer_service_results_like_group_dashboards.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(5);

select ok(not has_function_privilege('anon','public.get_customer_service_results_v1(date,date)','execute'),'anon cannot read results');
select ok(pg_get_functiondef('public.get_customer_service_results_v1(date,date)'::regprocedure) like '%require_customer_service_access%','results check permission');

set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub','a152b186-d484-49c5-8ead-406607113210','role','authenticated')::text,true);
create temp table r on commit drop as select public.get_customer_service_results_v1(current_date-365,current_date) as j;
select ok((select (j->'totals'->>'active_customers')::int>0 from r),'results count the active customers');
select is((select coalesce(sum((x->>'complaints')::int),0) from r,jsonb_array_elements(j->'by_product') x),(select (j->'totals'->>'complaints')::bigint from r),'by product adds up to the total');
select is((select coalesce(sum((x->>'complaints')::int),0) from r,jsonb_array_elements(j->'by_responsible') x),(select (j->'totals'->>'complaints')::bigint from r),'by responsible department adds up to the total');

select * from finish();
rollback;
