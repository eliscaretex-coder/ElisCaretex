begin;
select plan(9);

select has_function('public', 'move_sorting_staff_to_finish_table_v2', array['text','uuid','text','time without time zone','text'], 'move_sorting_staff_to_finish_table_v2 exists');
select has_function('public', 'restore_sorting_staff_from_finish_table_v2', array['text','uuid','text'], 'restore_sorting_staff_from_finish_table_v2 exists');

select ok(not has_function_privilege('anon', 'public.move_sorting_staff_to_finish_table_v2(text,uuid,text,time,text)', 'execute'), 'anon cannot call move_sorting_staff_to_finish_table_v2');
select ok(not has_function_privilege('anon', 'public.restore_sorting_staff_from_finish_table_v2(text,uuid,text)', 'execute'), 'anon cannot call restore_sorting_staff_from_finish_table_v2');

select ok(pg_get_functiondef('public.move_sorting_staff_to_finish_table_v2(text,uuid,text,time,text)'::regprocedure) like '%require_sorting_operational_access%', 'move v2 checks Sorting access');
select ok(pg_get_functiondef('public.restore_sorting_staff_from_finish_table_v2(text,uuid,text)'::regprocedure) like '%require_sorting_operational_access%', 'restore v2 checks Sorting access');

select ok(pg_get_functiondef('public.get_sorting_staff_dashboard_context_v2(text)'::regprocedure) like '%SORTING_TO_FINISH_TRANSFER%', 'Sorting Staff list recognises Sorting-to-Finish moves');
select ok(pg_get_functiondef('public.get_sorting_staff_dashboard_context_v2(text)'::regprocedure) like '%partial_area_transfer%', 'Sorting Staff list flags partial moves');

-- Without a signed-in Sorting user the RPC is refused.
select throws_ok(
  $$select public.move_sorting_staff_to_finish_table_v2('MORNING', gen_random_uuid(), 'FINISH_TABLE_1', '10:00'::time, null)$$,
  null, null, 'move v2 refuses a caller without Sorting access'
);

select * from finish();
rollback;
