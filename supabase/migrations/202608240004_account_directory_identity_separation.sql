-- Account directory now reads direct account permissions when configured,
-- with a fallback to legacy Staff Master permissions for unchanged accounts.

create or replace function public.get_admin_account_access_directory(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_search text:=lower(nullif(trim(p_search),''));
begin
 if not public.has_any_role(array['ADMIN']) then raise exception using errcode='42501',message='Only administrators can view application accounts and access.'; end if;
 return jsonb_build_object(
 'summary',jsonb_build_object('total_accounts',(select count(*) from auth.users),'linked_staff',(select count(*) from auth.users u join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null),'terminal_accounts',(select count(*) from public.production_station_devices where active=true),'unlinked_accounts',(select count(*) from auth.users u left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null where sm.staff_id is null)),
 'available_roles',coalesce((select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r where r.active=true),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg(jsonb_build_object(
  'auth_user_id',u.id,'email',u.email,'is_active',(u.banned_until is null or u.banned_until<=now()),'created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
  'staff_id',sm.staff_id,'employee_code',sm.employee_code,'display_name',coalesce(ap.display_name,sm.display_name),'staff_active',sm.active,'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
  'role_codes',coalesce((select jsonb_agg(r.role_code order by r.role_code) from public.roles r where r.active=true and (
   exists(select 1 from public.account_access_profiles ap2 join public.account_roles ar on ar.auth_user_id=ap2.auth_user_id and ar.role_id=r.role_id and ar.active=true where ap2.auth_user_id=u.id)
   or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active=true and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
  )),'[]'::jsonb),
  'terminal',case when psd.station_device_id is null then null else jsonb_build_object('device_code',psd.device_code,'device_name',psd.device_name,'station_code',s.station_code,'station_name',s.station_name,'area_code',a.area_code,'active',psd.active) end
 ) order by lower(coalesce(ap.display_name,sm.display_name,u.email)),u.created_at desc)
 from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null left join public.production_station_devices psd on psd.device_auth_user_id=u.id left join public.stations s on s.station_id=psd.station_id left join public.areas a on a.area_id=s.area_id
 where v_search is null or lower(coalesce(u.email,'')) like '%'||v_search||'%' or lower(coalesce(ap.display_name,sm.display_name,'')) like '%'||v_search||'%' or lower(coalesce(sm.employee_code,'')) like '%'||v_search||'%'),'[]'::jsonb)
 );
end;$$;

revoke all on function public.get_admin_account_access_directory(text) from public,anon;
grant execute on function public.get_admin_account_access_directory(text) to authenticated;
