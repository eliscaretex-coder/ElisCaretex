-- Move the existing legacy administrator identity to the explicit account model.
-- Roles are copied before the profile is created because profile presence disables
-- the legacy Staff Master role fallback.

insert into public.account_roles(auth_user_id,role_id,active)
select sm.auth_user_id,sr.role_id,true
from public.staff_members sm
join public.staff_roles sr on sr.staff_id=sm.staff_id
join public.roles r on r.role_id=sr.role_id and r.role_code='ADMIN' and r.active
where sm.auth_user_id is not null and sm.active and sm.deleted_at is null
  and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)
on conflict(auth_user_id,role_id) do update set active=true;

insert into public.account_access_profiles(auth_user_id,account_type,display_name,job_title_code,login_method)
select distinct sm.auth_user_id,'USER',sm.display_name,'ADMINISTRATOR','EMAIL'
from public.staff_members sm
join public.staff_roles sr on sr.staff_id=sm.staff_id
join public.roles r on r.role_id=sr.role_id and r.role_code='ADMIN' and r.active
where sm.auth_user_id is not null and sm.active and sm.deleted_at is null
  and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)
on conflict(auth_user_id) do update set
 account_type='USER',display_name=excluded.display_name,job_title_code='ADMINISTRATOR',login_method='EMAIL';

insert into public.account_permission_grants(
 auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage,granted_by_auth_user_id
)
select ap.auth_user_id,t.module_code,t.access_scope,t.can_view,t.can_create,t.can_edit,t.can_approve,t.can_manage,ap.auth_user_id
from public.account_access_profiles ap
join public.job_title_permission_templates t on t.job_title_code='ADMINISTRATOR'
where ap.job_title_code='ADMINISTRATOR'
on conflict(auth_user_id,module_code) do update set
 access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,
 can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage,
 active=true,effective_from=current_date,effective_until=null;
