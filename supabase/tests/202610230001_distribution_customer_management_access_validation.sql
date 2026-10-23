begin;
select plan(22);

select ok(not has_function_privilege('anon','public.require_customer_schedule_edit_role()','execute'),'anon cannot call the Customer Schedule edit guard');
select ok(not has_function_privilege('anon','public.get_customer_read_capabilities()','execute'),'anon cannot read customer capabilities');
select ok(not has_function_privilege('anon','public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)','execute'),'anon cannot update customers');

-- Every customer write keeps its audit_log insert (directly or through the function it calls).
select ok(pg_get_functiondef('public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text)'::regprocedure) like '%audit_log%','create_customer is audited');
select ok(pg_get_functiondef('public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)'::regprocedure) like '%audit_log%','update_customer is audited');
select ok(pg_get_functiondef('public.deactivate_customer(uuid,text,text)'::regprocedure) like '%audit_log%','deactivate_customer is audited');
select ok(pg_get_functiondef('public.reactivate_customer(uuid,text[],text,text)'::regprocedure) like '%audit_log%','reactivate_customer is audited');
select ok(pg_get_functiondef('public.publish_customer_schedule(uuid,text,text)'::regprocedure) like '%audit_log%','publish_customer_schedule is audited');
select ok(pg_get_functiondef('public.reorder_customer_planner_day(text,smallint,date,jsonb,text,text)'::regprocedure) like '%audit_log%','reorder_customer_planner_day is audited');

-- The patched role lists name DISTRIBUTION_OPERATOR.
select ok(pg_get_functiondef('public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text)'::regprocedure) like '%''PLANNER'', ''DISTRIBUTION_OPERATOR''%','create_customer allows Distribution');
select ok(pg_get_functiondef('public.publish_customer_schedule(uuid,text,text)'::regprocedure) like '%''PLANNER'', ''DISTRIBUTION_OPERATOR''%','publish_customer_schedule allows Distribution');
select ok(pg_get_functiondef('public.get_customer_directory(text,text,text,date,integer,integer)'::regprocedure) like '%''AUDITOR'', ''DISTRIBUTION_OPERATOR''%','get_customer_directory allows Distribution');

-- A Distribution account and a Finish account.
create temporary table t_distribution on commit drop as
select ar.auth_user_id from public.account_roles ar
join public.roles r on r.role_id=ar.role_id and r.role_code='DISTRIBUTION_OPERATOR'
where ar.active
  and not exists(select 1 from public.account_roles x join public.roles y on y.role_id=x.role_id
                 where x.auth_user_id=ar.auth_user_id and x.active and y.role_code in ('ADMIN','MANAGER','PLANNER'))
limit 1;
create temporary table t_finish on commit drop as
select ar.auth_user_id from public.account_roles ar
join public.roles r on r.role_id=ar.role_id and r.role_code='FINISH_OPERATOR'
where ar.active
  and not exists(select 1 from public.account_roles x join public.roles y on y.role_id=x.role_id
                 where x.auth_user_id=ar.auth_user_id and x.active
                   and y.role_code in ('ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR'))
limit 1;

select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from t_distribution),'role','authenticated')::text,true);
select lives_ok('select public.require_customer_schedule_edit_role()','Distribution edits Customer Schedules');
select lives_ok('select public.require_customer_schedule_history_role()','Distribution reads Customer Schedule history');
select ok((public.get_customer_read_capabilities()->>'can_edit_customers')::boolean,'Distribution can edit customers');
select ok((public.get_customer_read_capabilities()->>'can_publish_schedule_draft')::boolean,'Distribution can publish schedule revisions');
select ok((public.get_customer_read_capabilities()->>'can_review_operational_reports')::boolean,'Distribution can review trolley plan checks');
select ok(public.can_handle_trolley_plan_checks(),'Distribution can resolve trolley plan checks');
select lives_ok('select public.get_customer_directory(''ACTIVE'',''ALL'',null,public.current_business_date(),5,0)','Distribution reads the customer directory');
select throws_ok('select public.update_customer(gen_random_uuid(),1,''X'',''X'',null,null,null,null,null,array[''CLOTHES''],'''',''TEST'')','P0001','A change reason is required.','Distribution passes the permission check and still needs a change reason');

select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from t_finish),'role','authenticated')::text,true);
select throws_ok('select public.require_customer_schedule_edit_role()','42501','You do not have permission to manage Customer Schedules.','Finish is still refused Customer Schedule edits');
select throws_ok('select public.update_customer(gen_random_uuid(),1,''X'',''X'',null,null,null,null,null,array[''CLOTHES''],''test'',''TEST'')','P0001','Permission denied for customer update.','Finish is still refused customer updates');

select * from finish();
rollback;
