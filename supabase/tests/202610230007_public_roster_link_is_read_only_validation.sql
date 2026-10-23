begin;
select plan(5);

select ok(not has_function_privilege('anon','public.submit_production_roster_leave_request(text,uuid,text,date,date,text)','execute'),'public link cannot submit leave');
select ok(not has_function_privilege('authenticated','public.submit_production_roster_leave_request(text,uuid,text,date,date,text)','execute'),'token leave submission closed for signed-in users too');
select ok(not has_function_privilege('anon','public.get_my_production_roster_leave_requests(text,uuid)','execute'),'public link cannot read leave requests');
select ok(has_function_privilege('anon','public.get_published_production_roster_portal(text)','execute'),'public link still shows the roster');
select ok(has_function_privilege('authenticated','public.submit_my_account_leave_request(text,date,date,text)','execute'),'signed-in leave request still open');

select * from finish();
rollback;
