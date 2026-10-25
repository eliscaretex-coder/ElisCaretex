-- Validation for 202610250006_supervisors_managers_edit_customers_and_staff_master.sql.
-- Run against ElisCaretex-dev after the migration is applied. Read-only: rolled back.
begin;
select plan(17);

-- Templates.
select ok((select can_view and can_create and can_edit and not can_manage from public.job_title_permission_templates where job_title_code='PRODUCTION_SUPERVISOR' and module_code='CUSTOMERS'),'Production Supervisor template edits Customers (no deactivate)');
select ok((select can_view and can_create and can_edit from public.job_title_permission_templates where job_title_code='PRODUCTION_MANAGER' and module_code='CUSTOMERS'),'Production Manager template edits Customers');
select ok((select can_create and can_edit and can_approve and not can_manage from public.job_title_permission_templates where job_title_code='PRODUCTION_SUPERVISOR' and module_code='STAFF_MASTER'),'Production Supervisor template edits and approves in Staff Master (no deactivate)');
select ok((select can_create and can_edit and can_approve from public.job_title_permission_templates where job_title_code='GENERAL_MANAGER' and module_code='STAFF_MASTER'),'General Manager template edits Staff Master');
select ok((select can_view and not (can_create or can_edit or can_approve or can_manage) from public.job_title_permission_templates where job_title_code='AUDITOR' and module_code='CUSTOMERS'),'Auditor stays read-only on Customers');

-- Existing accounts follow their template.
select is((select count(*) from public.account_permission_grants g join public.account_access_profiles ap using (auth_user_id)
  where ap.account_type='USER' and ap.job_title_code in ('PRODUCTION_MANAGER','PRODUCTION_SUPERVISOR') and g.module_code='CUSTOMERS' and g.active and g.can_view and not g.can_edit),
  0::bigint,'every supervisor/manager account that sees Customers can edit them');
select ok(exists(select 1 from public.audit_log where action='WIDEN_ACCOUNT_PERMISSION_GRANT' and source_application='migration 202610250006'),'the permission change itself is recorded in audit_log');

-- Production Supervisor, as the signed-in user.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='PRODUCTION_SUPERVISOR' and account_type='USER' limit 1),'role','authenticated')::text,true);
select ok((public.get_customer_read_capabilities()->>'can_edit_customers')::boolean,'Supervisor can edit customers');
select ok((public.get_customer_read_capabilities()->>'can_publish_schedule_draft')::boolean,'Supervisor can edit and publish schedules');
select ok(not (public.get_customer_read_capabilities()->>'can_deactivate_customers')::boolean,'Supervisor cannot deactivate customers');
select ok(public.staff_master_action_allowed('EDIT') and public.staff_master_action_allowed('CREATE'),'Supervisor can edit Staff Master');
select ok(not public.staff_master_action_allowed('MANAGE'),'Supervisor cannot deactivate staff');
select ok(public.driver_role_transfer_can_approve('GENERAL_OPERATIVE'),'Supervisor approves a transfer into a lower job title');
select ok(not public.driver_role_transfer_can_approve('PRODUCTION_MANAGER'),'Supervisor cannot approve a transfer into a higher job title');

-- A real customer edit by the supervisor is recorded with before/after.
select lives_ok(format(
  'select public.update_customer(%L::uuid,%s,%L,%L,%L,%s,%s,%L,%L,%L::text[],%L,%L)',
  c.customer_id, c.row_version, c.customer_code, c.customer_name, c.eircode,
  coalesce(c.distribution_estimated_kg::text,'null'), coalesce(c.distribution_stop_count::text,'null'),
  coalesce(c.notes,'') || ' [validation]', c.operational_alert,
  (select array_agg(pt.product_code) from public.customer_product_services s join public.product_types pt using (product_type_id)
    where s.customer_id=c.customer_id and s.active and s.deleted_at is null and (s.effective_until is null or s.effective_until>=current_date)),
  'validation 202610250006','VALIDATION'),'Supervisor saves a customer edit')
from (select * from public.customers where active and deleted_at is null order by customer_code limit 1) c;
select ok(exists(select 1 from public.audit_log where action='UPDATE_CUSTOMER' and reason='validation 202610250006'
  and actor_auth_user_id=auth.uid() and old_data is not null and new_data is not null),'the edit is in audit_log with who, before and after');

-- Negative: an account without Customers is still refused.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CLEANER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_customer_read_capabilities()$$,'42501',null,'Cleaner cannot open Customers');

select * from finish();
rollback;
