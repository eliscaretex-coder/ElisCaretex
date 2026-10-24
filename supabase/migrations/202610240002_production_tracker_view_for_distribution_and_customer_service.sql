-- Production Tracker read-only access for Distribution and Customer Service (owner request 2026-10-24).
--
-- The tracker page only reads get_production_tracker_v4, which already accepts
-- PRODUCTION_TRACKER VIEW through require_production_flow_read_role(). This adds that
-- permission (view only) to the Logistics Manager and Customer Service job-title templates
-- and to the existing accounts with those job titles. Grants are only widened, never reduced.
-- Driver is left out on purpose: it keeps My Driver Roster only (202610230008).

with rows(job_title_code, module_code, access_scope) as (values
  ('LOGISTICS_MANAGER','PRODUCTION_TRACKER','DISTRIBUTION'),
  ('CUSTOMER_SERVICE','PRODUCTION_TRACKER','ALL')
), tpl as (
  insert into public.job_title_permission_templates(job_title_code, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
  select job_title_code, module_code, access_scope, true, false, false, false, false from rows
  on conflict (job_title_code, module_code) do update set can_view = true
  returning 1
)
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage, granted_by_auth_user_id)
select ap.auth_user_id, r.module_code, r.access_scope, true, false, false, false, false, null
from rows r
join public.account_access_profiles ap on ap.job_title_code = r.job_title_code and ap.account_type = 'USER'
on conflict (auth_user_id, module_code) do update set
  can_view = true,
  active = true,
  updated_at = now();
