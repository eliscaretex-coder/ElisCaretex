begin;
select plan(2);

select ok(pg_get_functiondef('public.restore_sorting_staff_from_finish_table_v2(text,uuid,text)'::regprocedure) not like '%ended_at = started_at%', 'restore v2 no longer writes a zero-length segment');
select ok(not has_function_privilege('anon', 'public.restore_sorting_staff_from_finish_table_v2(text,uuid,text)', 'execute'), 'anon cannot call restore_sorting_staff_from_finish_table_v2');

select * from finish();
rollback;
