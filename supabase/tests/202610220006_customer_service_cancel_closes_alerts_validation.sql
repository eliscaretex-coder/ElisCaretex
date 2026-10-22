-- Validation for 202610220006_customer_service_cancel_closes_alerts.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(6);

select ok(not has_function_privilege('anon','public.set_customer_service_complaint_status_v1(uuid,text,text,text)','execute'),'anon cannot change complaint status');
select ok(not exists(select 1 from public.customer_service_alerts a join public.customer_service_complaints c on c.complaint_id=a.complaint_id
  where c.status='CANCELLED' and a.ended_at is null),'no cancelled complaint keeps an open alert');

create temporary table cs_probe(c jsonb, a jsonb, t jsonb, r jsonb, d jsonb) on commit drop;
grant all on cs_probe to authenticated;
select set_config('cs.cust',(select customer_id::text from public.customers where active and deleted_at is null order by customer_name limit 1),true);
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap where ap.job_title_code='ADMINISTRATOR' limit 1),'role','authenticated')::text,true);
insert into cs_probe(c) select public.save_customer_service_complaint_v1(null,current_setting('cs.cust')::uuid,current_date,'LOST_ITEM','Validation complaint','HIGH',null,'PHONE',null);
update cs_probe set a=public.save_customer_service_alert_v1(null,current_setting('cs.cust')::uuid,'Validation alert',array['FINISH'],null,null,(c->>'complaint_id')::uuid);
update cs_probe set t=public.save_customer_service_task_v1(null,'FINISH','Validation task',null,null,(c->>'complaint_id')::uuid,null);
update cs_probe set r=public.set_customer_service_complaint_status_v1((c->>'complaint_id')::uuid,'CANCELLED',null,'Logged twice');
update cs_probe set d=public.get_customer_service_complaint_v1((c->>'complaint_id')::uuid);

select is((select r->>'status' from cs_probe),'CANCELLED','complaint cancelled');
select is((select d->'alerts'->0->>'state' from cs_probe),'ENDED','its alert is ended');
select is((select d->'tasks'->0->>'status' from cs_probe),'CANCELLED','its open task is cancelled');
select ok(not exists(select 1 from jsonb_array_elements(public.get_production_customer_alerts_v1('FINISH')->'alerts') x
  where x->>'alert_id'=(select a->>'alert_id' from cs_probe)),'Finish no longer sees the alert');

select * from finish();
rollback;
