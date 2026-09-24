-- Scope account administration catalogues and directory results to the caller.

create or replace function public.current_account_permission_scope(p_module_code text)
returns text language sql stable security definer set search_path=public,auth,pg_temp as $$
 select case
  when auth.uid() is null then null
  when public.has_any_role(array['ADMIN']) then 'ALL'
  else (select g.access_scope from public.account_permission_grants g
        where g.auth_user_id=auth.uid() and g.module_code=upper(trim(p_module_code)) and g.active
          and g.effective_from<=current_date and (g.effective_until is null or g.effective_until>=current_date)
        order by case g.access_scope when 'ALL' then 1 when 'PRODUCTION' then 2 when 'DISTRIBUTION' then 3 when 'TEAM' then 4 else 5 end limit 1)
 end;
$$;

create or replace function public.get_admin_account_job_access()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_scope text;
begin
 if not public.has_account_permission('ACCOUNTS_ACCESS','VIEW',null) then raise exception using errcode='42501',message='This account cannot view Accounts & Access.'; end if;
 v_scope:=public.current_account_permission_scope('ACCOUNTS_ACCESS');
 return jsonb_build_object(
  'job_titles',coalesce((select jsonb_agg(jsonb_build_object(
    'job_title_code',jt.job_title_code,'job_title_name',jt.job_title_name,'department_scope',jt.department_scope,
    'legacy_roles',coalesce((select jsonb_agg(jlr.role_code order by jlr.role_code) from public.job_title_legacy_roles jlr where jlr.job_title_code=jt.job_title_code),'[]'::jsonb),
    'permissions',coalesce((select jsonb_agg(to_jsonb(t)-'job_title_code' order by t.module_code) from public.job_title_permission_templates t where t.job_title_code=jt.job_title_code),'[]'::jsonb)
  ) order by jt.hierarchy_rank,jt.job_title_name) from public.account_job_titles jt where jt.active and (v_scope='ALL' or jt.department_scope=v_scope)),'[]'::jsonb),
  'profiles',coalesce((select jsonb_agg(jsonb_build_object('auth_user_id',ap.auth_user_id,'job_title_code',ap.job_title_code,'login_method',ap.login_method,'login_identifier',ap.login_identifier))
    from public.account_access_profiles ap left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code
    where v_scope='ALL' or ap.auth_user_id=auth.uid() or jt.department_scope=v_scope),'[]'::jsonb)
 );
end;$$;

create or replace function public.get_admin_account_access_directory(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_search text:=lower(nullif(trim(p_search),'')); v_scope text;
begin
 if not public.has_account_permission('ACCOUNTS_ACCESS','VIEW',null) then raise exception using errcode='42501',message='This account cannot view Accounts & Access.'; end if;
 v_scope:=public.current_account_permission_scope('ACCOUNTS_ACCESS');
 return jsonb_build_object(
 'summary',jsonb_build_object(
   'total_accounts',(select count(*) from auth.users u left join public.account_access_profiles sap on sap.auth_user_id=u.id left join public.account_job_titles sjt on sjt.job_title_code=sap.job_title_code where v_scope='ALL' or u.id=auth.uid() or sjt.department_scope=v_scope),
   'linked_staff',(select count(*) from auth.users u join public.staff_members ssm on ssm.auth_user_id=u.id and ssm.deleted_at is null left join public.account_access_profiles sap on sap.auth_user_id=u.id left join public.account_job_titles sjt on sjt.job_title_code=sap.job_title_code where v_scope='ALL' or u.id=auth.uid() or sjt.department_scope=v_scope),
   'terminal_accounts',(select count(*) from public.production_station_devices spsd where spsd.active=true and v_scope='ALL'),
   'unlinked_accounts',(select count(*) from auth.users u left join public.staff_members ssm on ssm.auth_user_id=u.id and ssm.deleted_at is null left join public.account_access_profiles sap on sap.auth_user_id=u.id left join public.account_job_titles sjt on sjt.job_title_code=sap.job_title_code where ssm.staff_id is null and (v_scope='ALL' or u.id=auth.uid() or sjt.department_scope=v_scope))
 ),
 'available_roles',coalesce((select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r where r.active=true),'[]'::jsonb),
 'available_modules',coalesce((select jsonb_agg(jsonb_build_object('module_code',m.module_code,'module_name',m.module_name,'module_group',m.module_group) order by m.display_order,m.module_name) from public.application_modules m where m.active),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg(jsonb_build_object(
  'auth_user_id',u.id,'email',u.email,'is_active',(u.banned_until is null or u.banned_until<=now()),'created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
  'staff_id',sm.staff_id,'employee_code',sm.employee_code,'display_name',coalesce(ap.display_name,sm.display_name),'staff_active',sm.active,'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
  'role_codes',coalesce((select jsonb_agg(r.role_code order by r.role_code) from public.roles r where r.active=true and (exists(select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active) or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date))))),'[]'::jsonb),
  'permissions',coalesce((select jsonb_agg(jsonb_build_object('module_code',g.module_code,'access_scope',g.access_scope,'can_view',g.can_view,'can_create',g.can_create,'can_edit',g.can_edit,'can_approve',g.can_approve,'can_manage',g.can_manage,'effective_from',g.effective_from,'effective_until',g.effective_until) order by g.module_code) from public.account_permission_grants g where g.auth_user_id=u.id and g.active),'[]'::jsonb),
  'terminal',case when psd.station_device_id is null then null else jsonb_build_object('device_code',psd.device_code,'device_name',psd.device_name,'station_code',s.station_code,'station_name',s.station_name,'area_code',a.area_code,'active',psd.active) end
 ) order by lower(coalesce(ap.display_name,sm.display_name,u.email)),u.created_at desc)
 from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null left join public.production_station_devices psd on psd.device_auth_user_id=u.id left join public.stations s on s.station_id=psd.station_id left join public.areas a on a.area_id=s.area_id
 where (v_scope='ALL' or ap.auth_user_id=auth.uid() or jt.department_scope=v_scope)
   and (v_search is null or lower(coalesce(u.email,'')) like '%'||v_search||'%' or lower(coalesce(ap.display_name,sm.display_name,'')) like '%'||v_search||'%' or lower(coalesce(sm.employee_code,'')) like '%'||v_search||'%')),'[]'::jsonb)
 );
end;$$;

revoke all on function public.current_account_permission_scope(text),public.get_admin_account_job_access(),public.get_admin_account_access_directory(text) from public,anon;
grant execute on function public.current_account_permission_scope(text),public.get_admin_account_job_access(),public.get_admin_account_access_directory(text) to authenticated;
