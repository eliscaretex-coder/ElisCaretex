-- Validation for 202610280008_customer_master_change_history.
-- Edits one live customer inside the transaction and rolls everything back.
begin;
select plan(17);

select has_function('public','get_customer_master_change_history',array['uuid'],'get_customer_master_change_history exists');
select ok(not has_function_privilege('anon','public.get_customer_master_change_history(uuid)','execute'),'anon cannot read customer history');
select ok(not has_function_privilege('anon','public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)','execute'),'anon cannot update customers');
select ok(pg_get_functiondef('public.get_customer_master_change_history(uuid)'::regprocedure) like '%account_module_allowed(array[''CUSTOMERS''],''VIEW''%','history checks CUSTOMERS:VIEW');

-- An account that can edit Customers.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'CUSTOMERS' and g.active and g.can_edit limit 1),'role','authenticated')::text, true);

create temporary table _c on commit drop as
select c.*, (
  select array_agg(pt.product_code order by pt.product_code)
  from public.customer_product_services s join public.product_types pt using (product_type_id)
  where s.customer_id = c.customer_id and s.active and s.effective_until is null and s.deleted_at is null
) as services
from public.customers c
where c.active and c.deleted_at is null
  and exists (select 1 from public.customer_product_services s where s.customer_id = c.customer_id and s.active and s.effective_until is null and s.deleted_at is null)
order by c.customer_code limit 1;
grant select on _c to authenticated;

-- 1. The reason must be written by the person.
select throws_ok($$select public.update_customer(customer_id,row_version,customer_code,customer_name || ' X',eircode,distribution_estimated_kg,distribution_stop_count,notes,operational_alert,services,'','VALIDATION') from _c$$,'22023',null,'an empty reason is refused');
select throws_ok($$select public.update_customer(customer_id,row_version,customer_code,customer_name || ' X',eircode,distribution_estimated_kg,distribution_stop_count,notes,operational_alert,services,'typo','VALIDATION') from _c$$,'22023',null,'a reason shorter than 10 characters is refused');
select throws_ok($$select public.update_customer(customer_id,row_version,customer_code,customer_name || ' X',eircode,distribution_estimated_kg,distribution_stop_count,notes,operational_alert,services,'Updated Customer Master for X: customer name.','VALIDATION') from _c$$,'22023',null,'the old automatic reason is refused');

-- 2. An edit that changes nothing is refused.
select throws_ok($$select public.update_customer(customer_id,row_version,customer_code,customer_name,eircode,distribution_estimated_kg,distribution_stop_count,notes,operational_alert,services,'Validation: nothing changed here','VALIDATION') from _c$$,'22023',null,'an edit without changes is refused');

-- 3. A real edit is saved and recorded with the services before and after.
select lives_ok($$select public.update_customer(customer_id,row_version,customer_code,customer_name || ' VALIDATION',eircode,distribution_estimated_kg,distribution_stop_count,notes,operational_alert,services,'Validation: customer renamed by the test','VALIDATION') from _c$$,'a rename with a written reason is saved');
select ok(exists(select 1 from public.audit_log l, _c where l.entity_id = _c.customer_id::text and l.action = 'UPDATE_CUSTOMER'
  and l.reason = 'Validation: customer renamed by the test' and l.actor_auth_user_id = auth.uid()
  and l.old_data ? 'product_services' and l.new_data ? 'product_services'),'the audit row has who, the reason and the services');

-- 4. The history shows the edit first, with the person, the reason and the field change.
create temporary table _h on commit drop as select public.get_customer_master_change_history(customer_id) h from _c;
select is((select h->'entries'->0->>'reason' from _h),'Validation: customer renamed by the test','history shows the newest reason first');
select ok((select h->'entries'->0->>'actor_name' from _h) is not null,'history names the person');
select is((select jsonb_array_length(h->'entries'->0->'changes') from _h),1,'only the changed field is listed');
select is((select h->'entries'->0->'changes'->0->>'label' from _h),'Customer name','the change is the customer name');
select is((select (h->'entries'->0->'changes'->0->>'after') from _h),(select customer_name || ' VALIDATION' from _c),'the new name is shown');
select is((select (h->'entries'->0->'changes'->0->>'before') from _h),(select customer_name from _c),'the old name is shown');

-- 5. An account without Customers cannot read the history.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CLEANER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_customer_master_change_history(customer_id) from _c$$,'42501',null,'Cleaner cannot read customer history');

select * from finish();
rollback;
