begin;

insert into public.account_permission_grants(
  auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage,granted_by_auth_user_id
)
select ap.auth_user_id,t.module_code,t.access_scope,t.can_view,t.can_create,t.can_edit,t.can_approve,t.can_manage,auth.uid()
from public.account_access_profiles ap
join public.job_title_permission_templates t on t.job_title_code=ap.job_title_code and t.module_code='MY_DRIVER_ROSTER'
on conflict(auth_user_id,module_code) do update set
 access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,
 can_approve=excluded.can_approve,can_manage=excluded.can_manage,active=true,updated_at=now();

commit;
