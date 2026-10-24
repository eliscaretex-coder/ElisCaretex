-- Validation for 202610240002_production_tracker_view_for_distribution_and_customer_service.sql.
-- Run against ElisCaretex-dev after the migration is applied. Read-only: rolled back.
begin;
select plan(7);

-- Templates: view only.
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='LOGISTICS_MANAGER' and module_code='PRODUCTION_TRACKER' and can_view and not (can_create or can_edit or can_approve or can_manage)),'Logistics Manager template has Production Tracker view only');
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='CUSTOMER_SERVICE' and module_code='PRODUCTION_TRACKER' and can_view and not (can_create or can_edit or can_approve or can_manage)),'Customer Service template has Production Tracker view only');
select ok(not exists(select 1 from public.job_title_permission_templates where job_title_code='DRIVER' and module_code='PRODUCTION_TRACKER'),'Driver template does not get Production Tracker');

-- Every existing Logistics Manager / Customer Service account has the grant.
select is((select count(*) from public.account_access_profiles ap
  where ap.account_type='USER' and ap.job_title_code in ('LOGISTICS_MANAGER','CUSTOMER_SERVICE')
    and not exists(select 1 from public.account_permission_grants g where g.auth_user_id=ap.auth_user_id and g.module_code='PRODUCTION_TRACKER' and g.active and g.can_view)),
  0::bigint,'existing Logistics Manager and Customer Service accounts can view Production Tracker');

-- Positive: a Logistics Manager reads the tracker but cannot edit it.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='LOGISTICS_MANAGER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select ok(public.has_account_permission('PRODUCTION_TRACKER','VIEW',null),'Logistics Manager has Production Tracker view');
select ok(not public.has_account_permission('PRODUCTION_TRACKER','EDIT',null),'Logistics Manager has no Production Tracker edit');
select is(public.get_production_tracker_v4(null)->>'schema_version','PRODUCTION_TRACKER_V4','Logistics Manager gets the tracker');

select * from finish();
rollback;
