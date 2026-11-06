-- Validation for 202611060011_customer_service_task_for_a_person.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
-- (The rolled-back block in the shared folder, teste-sem-gravar.sql, runs the full
-- task for a GO / task for a supervisor / inbox / mark done flow before applying.)
begin;
select plan(9);

select has_column('public','customer_service_tasks','assigned_staff_id','tasks can go to a Staff Master person');
select has_column('public','customer_service_tasks','assigned_auth_user_id','tasks can go to a sign-in');
select has_function('public','save_customer_service_task_v2',array['uuid','text','text','text','date','uuid','uuid','text'],'save task v2 exists');
select ok(not has_function_privilege('anon','public.save_customer_service_task_v2(uuid,text,text,text,date,uuid,uuid,text)','execute'),'anon cannot save tasks');
select ok(not has_function_privilege('anon','public.complete_my_customer_service_task_v1(uuid,text)','execute'),'anon cannot complete tasks');
select ok(not has_function_privilege('anon','public.get_customer_service_task_people_v1()','execute'),'anon cannot list people');
select ok(not has_function_privilege('authenticated','public.customer_service_my_open_tasks()','execute'),'my open tasks helper is internal');
select ok(pg_get_functiondef('public.get_customer_service_task_people_v1()'::regprocedure) like '%require_customer_service_access%','listing people checks permission');

-- Someone with no task assigned cannot complete a random task.
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub','a152b186-d484-49c5-8ead-406607113210','role','authenticated')::text,true);
select throws_ok($$select public.complete_my_customer_service_task_v1(gen_random_uuid(),'done')$$,'P0002',null,'a task that is not yours cannot be completed');

select * from finish();
rollback;
