-- IT Manager: the same access as the Administrator, except the Administrator itself.
--
-- The owner asked for an IT Manager account "similar to the Administrator, but it cannot
-- remove or change the Administrator's permissions".
--
-- How this is enforced:
--   * IT_MANAGER gets every module the Administrator job title has, with the same scope
--     and actions (copied from the ADMINISTRATOR template, so later Administrator module
--     changes can be re-synced the same way).
--   * IT_MANAGER gets every active legacy role EXCEPT ADMIN. Without the ADMIN role the
--     admin-account-management Edge Function (since 202611050004 / PR #177) refuses, for a
--     non-administrator: changing, disabling, deleting or re-inviting an account that holds
--     ADMIN; giving the Administrator job title; changing its own job title or permissions;
--     giving any access it does not hold itself.
--   * Database-only Administrator checks (has_any_role(array['ADMIN'])) stay Administrator
--     only, for example the General Manager email for long Holiday approvals.
--   * Hierarchy rank stays 10 (Administrator is 1), so job-title changes from Staff Master
--     and driver transfers can never move someone to or from Administrator.
--
-- Data only; no grants or functions change. Safe to run again.

begin;

delete from public.job_title_permission_templates where job_title_code = 'IT_MANAGER';

insert into public.job_title_permission_templates
  (job_title_code, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
select 'IT_MANAGER', t.module_code, t.access_scope, t.can_view, t.can_create, t.can_edit, t.can_approve, t.can_manage
from public.job_title_permission_templates t
where t.job_title_code = 'ADMINISTRATOR';

delete from public.job_title_legacy_roles where job_title_code = 'IT_MANAGER';

insert into public.job_title_legacy_roles (job_title_code, role_code)
select 'IT_MANAGER', r.role_code
from public.roles r
where r.active and r.role_code <> 'ADMIN';

-- Accounts that already hold the IT Manager title get the new standard access.
select public.apply_account_job_title_template(ap.auth_user_id, 'IT_MANAGER', null)
from public.account_access_profiles ap
where ap.job_title_code = 'IT_MANAGER' and ap.account_type = 'USER';

do $$
begin
  if exists (select 1 from public.job_title_legacy_roles where job_title_code = 'IT_MANAGER' and role_code = 'ADMIN') then
    raise exception 'IT_MANAGER must never hold the ADMIN role.';
  end if;
  if (select count(*) from public.job_title_permission_templates where job_title_code = 'IT_MANAGER')
     <> (select count(*) from public.job_title_permission_templates where job_title_code = 'ADMINISTRATOR') then
    raise exception 'IT_MANAGER modules do not match the Administrator modules.';
  end if;
  if (select hierarchy_rank from public.account_job_titles where job_title_code = 'IT_MANAGER')
     <= (select hierarchy_rank from public.account_job_titles where job_title_code = 'ADMINISTRATOR') then
    raise exception 'IT_MANAGER must rank below the Administrator.';
  end if;
end $$;

commit;
