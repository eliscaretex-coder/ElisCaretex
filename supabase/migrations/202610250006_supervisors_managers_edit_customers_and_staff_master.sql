-- Supervisors and managers edit Customers and Staff Master (owner request 2026-10-25).
--
-- Owner: every supervisor, manager and Distribution account that can already see the
-- Customers list, the Schedule Planner and the Customer Master can also edit them, and
-- the Production Supervisor approves role transfers in Staff Master. Every change must
-- stay recorded.
--
-- Customers (list, Schedule Planner and Customer Master are one module, CUSTOMERS):
--   PRODUCTION_MANAGER and PRODUCTION_SUPERVISOR: view -> view + create + edit.
--   GENERAL_MANAGER (manage) and LOGISTICS_MANAGER (edit) already edit: unchanged.
--   Deactivate/reactivate a customer stays CUSTOMERS:MANAGE (General Manager, Admin).
-- Staff Master (STAFF_MASTER):
--   GENERAL_MANAGER: view + approve -> also create + edit.
--   PRODUCTION_SUPERVISOR: view + edit -> also create + approve. Approval keeps the
--   hierarchy rule in driver_role_transfer_can_approve: a supervisor approves only
--   transfers into a job title ranked below Production Supervisor.
--   Deactivating staff stays STAFF_MASTER:MANAGE (Production Manager, Admin).
-- Only accounts that already hold the module are widened; nothing is reduced and no
-- module is added to an account that did not have it. Auditor stays read-only.
--
-- Recording: the customer, schedule and Staff Master RPCs already write audit_log
-- (who, when, old_data, new_data, reason). This migration also writes one audit_log
-- row per template and account grant it changes.

create temporary table _edit_access_change(job_title_code text, module_code text, add_create boolean, add_edit boolean, add_approve boolean) on commit drop;
insert into _edit_access_change values
  ('PRODUCTION_MANAGER',    'CUSTOMERS',    true,  true,  false),
  ('PRODUCTION_SUPERVISOR', 'CUSTOMERS',    true,  true,  false),
  ('GENERAL_MANAGER',       'STAFF_MASTER', true,  true,  false),
  ('PRODUCTION_SUPERVISOR', 'STAFF_MASTER', true,  false, true);

with changed as (
  select t.job_title_code, t.module_code, to_jsonb(t) as old_row
  from public.job_title_permission_templates t
  join _edit_access_change c using (job_title_code, module_code)
  where t.can_view
    and ((c.add_create and not t.can_create) or (c.add_edit and not t.can_edit) or (c.add_approve and not t.can_approve))
), upd as (
  update public.job_title_permission_templates t set
    can_create = t.can_create or c.add_create,
    can_edit = t.can_edit or c.add_edit,
    can_approve = t.can_approve or c.add_approve
  from _edit_access_change c, changed ch
  where t.job_title_code = c.job_title_code and t.module_code = c.module_code
    and ch.job_title_code = t.job_title_code and ch.module_code = t.module_code
  returning t.*, ch.old_row
)
insert into public.audit_log(actor_auth_user_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
select null, 'WIDEN_JOB_TITLE_PERMISSION_TEMPLATE', 'job_title_permission_templates',
  u.job_title_code || ':' || u.module_code, u.old_row, to_jsonb(u) - 'old_row',
  'Owner request 2026-10-25: supervisors and managers edit Customers and Staff Master',
  'migration 202610250006'
from upd u;

with changed as (
  select g.auth_user_id, g.module_code, to_jsonb(g) as old_row
  from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  join _edit_access_change c on c.job_title_code = ap.job_title_code and c.module_code = g.module_code
  where g.active and g.can_view
    and ((c.add_create and not g.can_create) or (c.add_edit and not g.can_edit) or (c.add_approve and not g.can_approve))
), upd as (
  update public.account_permission_grants g set
    can_create = g.can_create or c.add_create,
    can_edit = g.can_edit or c.add_edit,
    can_approve = g.can_approve or c.add_approve,
    updated_at = now()
  from public.account_access_profiles ap, _edit_access_change c, changed ch
  where ap.auth_user_id = g.auth_user_id
    and c.job_title_code = ap.job_title_code and c.module_code = g.module_code
    and ch.auth_user_id = g.auth_user_id and ch.module_code = g.module_code
  returning g.*, ch.old_row
)
insert into public.audit_log(actor_auth_user_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
select null, 'WIDEN_ACCOUNT_PERMISSION_GRANT', 'account_permission_grants',
  u.auth_user_id::text || ':' || u.module_code, u.old_row, to_jsonb(u) - 'old_row',
  'Owner request 2026-10-25: supervisors and managers edit Customers and Staff Master',
  'migration 202610250006'
from upd u;
