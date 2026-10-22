-- Customer Service: leave Administrator accounts out of the Customer Service team list.
--
-- An Administrator account needs the CUSTOMER_SERVICE permission to see the menu (accounts
-- with module permissions get their menu from those permissions only), but is not one of
-- the people who share the customer blocks. Only the "agents" list changes; access is the
-- same as before.

create or replace function public.get_customer_service_workspace_v1()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_scope text; v_today date;
begin
  perform public.require_customer_service_access('VIEW');
  v_scope:=public.customer_service_access_scope();
  v_today:=public.customer_service_today();
  return jsonb_build_object(
    'schema_version','CUSTOMER_SERVICE_V1',
    'today',v_today,
    'me',jsonb_build_object('auth_user_id',auth.uid(),'display_name',public.customer_service_user_name(auth.uid()),'scope',v_scope,
      'can_create',public.customer_service_can('CREATE'),'can_edit',public.customer_service_can('EDIT'),'can_manage',public.customer_service_can('MANAGE')),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',cu.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
        'owner_auth_user_id',o.owner_auth_user_id,'owner_name',public.customer_service_user_name(o.owner_auth_user_id),'mine',o.owner_auth_user_id=auth.uid())
      order by lower(cu.customer_name)) from public.customers cu left join public.customer_service_customer_owners o on o.customer_id=cu.customer_id
      where cu.deleted_at is null and cu.active),'[]'::jsonb),
    'types',coalesce((select jsonb_agg(to_jsonb(t)-'created_at'-'updated_at' order by t.sort_order,t.type_name) from public.customer_service_complaint_types t),'[]'::jsonb),
    'agents',coalesce((select jsonb_agg(jsonb_build_object('auth_user_id',x.auth_user_id,'display_name',public.customer_service_user_name(x.auth_user_id),'scope',x.access_scope,'can_manage',x.can_manage)
      order by lower(public.customer_service_user_name(x.auth_user_id))) from (
        select g.auth_user_id,g.access_scope,g.can_manage from public.account_permission_grants g
        where g.module_code='CUSTOMER_SERVICE' and g.active and g.effective_from<=current_date and (g.effective_until is null or g.effective_until>=current_date)
          and (g.can_create or g.can_edit or g.can_manage)
          and not exists(select 1 from public.account_access_profiles ap where ap.auth_user_id=g.auth_user_id and ap.job_title_code='ADMINISTRATOR')) x),'[]'::jsonb),
    'counts',jsonb_build_object(
      'open_complaints',(select count(*) from public.customer_service_complaints c where c.status in ('OPEN','INVESTIGATING') and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id)),
      'active_alerts',(select count(*) from public.customer_service_alerts a where a.ended_at is null and a.starts_on<=v_today and (a.ends_on is null or a.ends_on>=v_today) and public.customer_service_customer_visible(a.customer_id,a.created_by_auth_user_id)),
      'open_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))),
      'overdue_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and k.due_on<v_today and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))))
  );
end;$$;

revoke all on function public.get_customer_service_workspace_v1() from public,anon;
grant execute on function public.get_customer_service_workspace_v1() to authenticated;
