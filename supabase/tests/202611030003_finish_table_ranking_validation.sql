-- Validation for 202611030003_finish_table_ranking.sql (read-only RPC).
-- Runs as the registered Finish computer FINISH-T1-PC01 and rolls back.
begin;
select plan(12);

select has_function('public', 'get_finish_table_ranking_v1', array['text', 'date'], 'get_finish_table_ranking_v1 exists');
select ok(not has_function_privilege('anon', 'public.get_finish_table_ranking_v1(text, date)', 'execute'), 'anon cannot call the ranking');
select ok(pg_get_functiondef('public.get_finish_table_ranking_v1(text, date)'::regprocedure) like '%require_finish_production_access%', 'ranking checks Finish access');
select throws_ok($$ select public.get_finish_table_ranking_v1('WEEK', null) $$, '42501', null, 'ranking refuses a caller without a Finish account');

select set_config('request.jwt.claims', json_build_object('sub', 'b2aef431-0a4c-4c52-aef0-b64cbdf7a5fe', 'role', 'authenticated')::text, true);
set local role authenticated;

select is(public.get_finish_table_ranking_v1('WEEK', null) ->> 'schema_version', 'FINISH_TABLE_RANKING_V1', 'schema version');
select is(jsonb_array_length(public.get_finish_table_ranking_v1('WEEK', null) -> 'teams'), 6, 'six Table x Shift teams');
select is(jsonb_array_length(public.get_finish_table_ranking_v1('WEEK', null) -> 'tables'), 3, 'three Tables');
select ok((public.get_finish_table_ranking_v1('WEEK', null) ->> 'date_to')::date < date_trunc('week', (now() at time zone 'Europe/Dublin')::date)::date, 'default week is closed');
select is(extract(day from (public.get_finish_table_ranking_v1('MONTH', null) ->> 'date_from')::date)::int, 1, 'month starts on day 1');
select ok(not exists (
  select 1 from jsonb_array_elements(public.get_finish_table_ranking_v1('WEEK', null) -> 'teams') x
  where abs((x ->> 'score')::numeric - ((x ->> 'efficiency_percent')::numeric - 2 * (x ->> 'trolley_error_percent')::numeric)) > 0.2
), 'score = efficiency - 2 x trolley error %');
select throws_ok($$ select public.get_finish_table_ranking_v1('WEEK', (now() at time zone 'Europe/Dublin')::date) $$, '22023', null, 'open week is refused');
select throws_ok($$ select public.get_finish_table_ranking_v1('YEAR', null) $$, '22023', null, 'unknown period is refused');

select * from finish();
rollback;
