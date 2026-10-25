-- Validation for 202610250004_production_intelligence_view_for_customer_service.sql.
-- Run against ElisCaretex-dev after the migration is applied. Read-only: rolled back.
begin;
select plan(7);

-- Template: view only.
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='CUSTOMER_SERVICE' and module_code='PRODUCTION_INSIGHTS' and can_view and not (can_create or can_edit or can_approve or can_manage)),'Customer Service template has Production Intelligence view only');
select ok(not exists(select 1 from public.job_title_permission_templates where job_title_code='DRIVER' and module_code='PRODUCTION_INSIGHTS'),'Driver template does not get Production Intelligence');

-- Every existing Customer Service account has the grant.
select is((select count(*) from public.account_access_profiles ap
  where ap.account_type='USER' and ap.job_title_code='CUSTOMER_SERVICE'
    and not exists(select 1 from public.account_permission_grants g where g.auth_user_id=ap.auth_user_id and g.module_code='PRODUCTION_INSIGHTS' and g.active and g.can_view)),
  0::bigint,'existing Customer Service accounts can view Production Intelligence');

-- Positive: a Customer Service account reads Production Intelligence but cannot edit it.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CUSTOMER_SERVICE' and account_type='USER' limit 1),'role','authenticated')::text,true);
select ok(public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null),'Customer Service has Production Intelligence view');
select ok(not public.has_account_permission('PRODUCTION_INSIGHTS','EDIT',null),'Customer Service has no Production Intelligence edit');
select is(public.get_production_intelligence_manager_view(current_date-27,current_date,'WEEK',null,null)->>'schema_version','PRODUCTION_INTELLIGENCE_MANAGER_V1','Customer Service gets the manager view');

-- Negative: a Driver is still refused.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='DRIVER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_production_intelligence_manager_view(current_date-27,current_date,'WEEK',null,null)$$,'42501',null,'Driver cannot read Production Intelligence');

select * from finish();
rollback;
