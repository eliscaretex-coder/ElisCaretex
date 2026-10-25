-- Production Intelligence read-only access for Customer Service (owner request 2026-10-25).
--
-- Every Production Intelligence RPC checks PRODUCTION_INSIGHTS VIEW. This adds that
-- permission (view only) to the Customer Service job-title template and to the existing
-- Customer Service accounts. Grants are only widened, never reduced.
-- The Daily report keeps the Sorting and Finish blocks behind their own modules
-- (get_production_daily_report shows them as DENIED for accounts without them).

with tpl as (
  insert into public.job_title_permission_templates(job_title_code, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
  values ('CUSTOMER_SERVICE','PRODUCTION_INSIGHTS','ALL',true,false,false,false,false)
  on conflict (job_title_code, module_code) do update set can_view = true
  returning 1
)
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage, granted_by_auth_user_id)
select ap.auth_user_id, 'PRODUCTION_INSIGHTS', 'ALL', true, false, false, false, false, null
from public.account_access_profiles ap
where ap.job_title_code = 'CUSTOMER_SERVICE' and ap.account_type = 'USER'
on conflict (auth_user_id, module_code) do update set
  can_view = true,
  active = true,
  updated_at = now();
