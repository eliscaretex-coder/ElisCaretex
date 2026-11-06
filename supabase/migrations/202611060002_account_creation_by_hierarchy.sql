-- Account creation follows the job-title hierarchy.
--
-- Owner request (2026-11-06): the Production Manager can create any job title up to
-- manager level except General Manager; the General Manager can create accounts too.
--
-- Rule (enforced in the admin-account-management Edge Function, mirrored here for the
-- screens): a non-administrator gives only job titles at their own hierarchy level or
-- below (hierarchy_rank >= their own; Administrator 1, IT Manager 10, General Manager
-- 20, Production/Logistics Manager 30, ...) and never the Administrator title. They act
-- only on accounts at their own level or below and never on an account holding ADMIN.
--
-- Changes:
--   1. Production Manager: Accounts & access scope PRODUCTION -> ALL (template and the
--      active grants of current Production Manager accounts), so the Logistics Manager,
--      Customer Service, Auditor and other titles at rank 30 or below are available.
--      The hierarchy keeps General Manager, IT Manager and Administrator out of reach.
--   2. get_admin_account_job_access returns hierarchy_rank and can_assign for each job
--      title, and my_hierarchy_rank / my_is_admin, so the screens list only the job
--      titles the signed-in account can give.

begin;

update public.job_title_permission_templates
set access_scope = 'ALL'
where job_title_code = 'PRODUCTION_MANAGER' and module_code = 'ACCOUNTS_ACCESS' and access_scope = 'PRODUCTION';

update public.account_permission_grants g
set access_scope = 'ALL', updated_at = now()
from public.account_access_profiles ap
where ap.auth_user_id = g.auth_user_id
  and ap.job_title_code = 'PRODUCTION_MANAGER'
  and g.module_code = 'ACCOUNTS_ACCESS'
  and g.active
  and g.access_scope = 'PRODUCTION';

create or replace function public.get_admin_account_job_access()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_scope text;
  v_is_admin boolean;
  v_my_rank integer;
begin
  if not public.has_account_permission('ACCOUNTS_ACCESS','VIEW',null) then
    raise exception using errcode='42501', message='This account cannot view Accounts & Access.';
  end if;
  v_scope := public.current_account_permission_scope('ACCOUNTS_ACCESS');
  v_is_admin := public.has_any_role(array['ADMIN']);
  select jt.hierarchy_rank into v_my_rank
  from public.account_access_profiles ap
  join public.account_job_titles jt on jt.job_title_code = ap.job_title_code
  where ap.auth_user_id = auth.uid() and ap.account_type = 'USER';

  return jsonb_build_object(
    'my_is_admin', v_is_admin,
    'my_hierarchy_rank', v_my_rank,
    'job_titles', coalesce((select jsonb_agg(jsonb_build_object(
        'job_title_code', jt.job_title_code,
        'job_title_name', jt.job_title_name,
        'department_scope', jt.department_scope,
        'hierarchy_rank', jt.hierarchy_rank,
        'can_assign', v_is_admin or (
          jt.job_title_code <> 'ADMINISTRATOR'
          and v_my_rank is not null and jt.hierarchy_rank is not null
          and jt.hierarchy_rank >= v_my_rank),
        'legacy_roles', coalesce((select jsonb_agg(jlr.role_code order by jlr.role_code) from public.job_title_legacy_roles jlr where jlr.job_title_code = jt.job_title_code), '[]'::jsonb),
        'permissions', coalesce((select jsonb_agg(to_jsonb(t) - 'job_title_code' order by t.module_code) from public.job_title_permission_templates t where t.job_title_code = jt.job_title_code), '[]'::jsonb)
      ) order by jt.hierarchy_rank, jt.job_title_name)
      from public.account_job_titles jt
      where jt.active and (v_scope = 'ALL' or jt.department_scope = v_scope)), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object(
        'auth_user_id', ap.auth_user_id,
        'job_title_code', ap.job_title_code,
        'login_method', ap.login_method,
        'login_identifier', ap.login_identifier))
      from public.account_access_profiles ap
      left join public.account_job_titles jt on jt.job_title_code = ap.job_title_code
      where v_scope = 'ALL' or ap.auth_user_id = auth.uid() or jt.department_scope = v_scope), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.get_admin_account_job_access() from public, anon;
grant execute on function public.get_admin_account_job_access() to authenticated, service_role;

do $$
begin
  if exists (select 1 from public.job_title_permission_templates
             where job_title_code = 'PRODUCTION_MANAGER' and module_code = 'ACCOUNTS_ACCESS' and access_scope <> 'ALL') then
    raise exception 'Production Manager Accounts & access scope was not widened.';
  end if;
  if exists (select 1 from public.job_title_permission_templates
             where job_title_code = 'PRODUCTION_MANAGER' and module_code = 'ACCOUNTS_ACCESS' and can_manage) then
    raise exception 'Production Manager must not get Manage on Accounts & access.';
  end if;
end $$;

commit;
