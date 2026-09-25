-- Scheduled staff exits and central account access enforcement.

create or replace function public.current_account_is_enabled()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and case
    when exists(select 1 from public.production_station_devices d where d.device_auth_user_id=auth.uid() and d.active) then true
    when exists(select 1 from public.staff_members linked where linked.auth_user_id=auth.uid() and linked.deleted_at is null)
      then exists(
        select 1 from public.staff_members active_staff
        where active_staff.auth_user_id=auth.uid()
          and active_staff.active
          and active_staff.deleted_at is null
          and (active_staff.deactivated_on is null or active_staff.deactivated_on >= current_date)
      )
    else true
  end;
$$;

revoke all on function public.current_account_is_enabled() from public,anon;
grant execute on function public.current_account_is_enabled() to authenticated;

create or replace function public.has_any_role(p_role_codes text[])
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.current_account_is_enabled() and exists (
    select 1 from public.roles r
    where r.active and r.role_code=any(p_role_codes) and (
      exists(select 1 from public.account_access_profiles ap join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.role_id=r.role_id and ar.active where ap.auth_user_id=auth.uid())
      or (not exists(select 1 from public.account_access_profiles ap where ap.auth_user_id=auth.uid()) and exists(
        select 1 from public.staff_members sm join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.role_id=r.role_id
        where sm.auth_user_id=auth.uid() and sm.active and sm.deleted_at is null and (sm.deactivated_on is null or sm.deactivated_on>=current_date)
          and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)
      ))
    )
  );
$$;

create or replace function public.has_account_permission(p_module_code text,p_action text,p_scope text default null)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.current_account_is_enabled() and (
    public.has_any_role(array['ADMIN']) or exists(
      select 1 from public.account_permission_grants apg
      where apg.auth_user_id=auth.uid() and apg.module_code=upper(trim(p_module_code)) and apg.active
        and apg.effective_from<=current_date and (apg.effective_until is null or apg.effective_until>=current_date)
        and (p_scope is null or apg.access_scope=upper(trim(p_scope)) or apg.access_scope='ALL')
        and case upper(trim(p_action))
          when 'VIEW' then apg.can_view or apg.can_create or apg.can_edit or apg.can_approve or apg.can_manage
          when 'CREATE' then apg.can_create or apg.can_manage
          when 'EDIT' then apg.can_edit or apg.can_manage
          when 'APPROVE' then apg.can_approve or apg.can_manage
          when 'MANAGE' then apg.can_manage
          else false end
    )
  );
$$;

create or replace function public.get_current_account_access()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'account_enabled',public.current_account_is_enabled(),
    'display_name',coalesce(ap.display_name,sm.display_name,u.email,'Signed in'),
    'employee_code',sm.employee_code,
    'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
    'job_title_code',ap.job_title_code,'login_method',ap.login_method,
    'role_codes',case when public.current_account_is_enabled() then coalesce((select jsonb_agg(r.role_code order by r.role_code) from public.roles r where r.active and (exists(select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active) or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date))))),'[]'::jsonb) else '[]'::jsonb end,
    'roles',case when public.current_account_is_enabled() then coalesce((select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r where r.active and (exists(select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active) or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date))))),'[]'::jsonb) else '[]'::jsonb end,
    'permissions',case when public.current_account_is_enabled() then coalesce((select jsonb_agg(jsonb_build_object('module_code',g.module_code,'access_scope',g.access_scope,'can_view',g.can_view,'can_create',g.can_create,'can_edit',g.can_edit,'can_approve',g.can_approve,'can_manage',g.can_manage) order by m.display_order,m.module_name) from public.account_permission_grants g join public.application_modules m on m.module_code=g.module_code and m.active where g.auth_user_id=u.id and g.active and g.effective_from<=current_date and (g.effective_until is null or g.effective_until>=current_date)),'[]'::jsonb) else '[]'::jsonb end
  )
  from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
  left join public.production_station_devices psd on psd.device_auth_user_id=u.id and psd.active
  where u.id=auth.uid();
$$;

create or replace function public.deactivate_staff_member(p_staff_id uuid,p_expected_row_version integer,p_deactivated_on date default current_date,p_reason text default null,p_source_application text default 'STAFF_MASTER_UI')
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_before jsonb; v_staff public.staff_members%rowtype; v_exit date:=coalesce(p_deactivated_on,current_date); v_immediate boolean;
begin
  perform public.require_staff_master_manage_role();
  if p_staff_id is null then raise exception 'Staff ID is required.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'A deactivation reason is required.'; end if;
  if exists(select 1 from public.staff_members sm where sm.staff_id=p_staff_id and sm.auth_user_id=auth.uid()) then raise exception 'You cannot deactivate your own signed-in staff profile.'; end if;
  v_before:=public.get_staff_master_record(p_staff_id); v_immediate:=v_exit<=current_date;
  update public.staff_members sm set active=not v_immediate,roster_eligible=case when v_immediate then false else sm.roster_eligible end,
    deactivated_on=v_exit,deactivation_reason=trim(p_reason),row_version=sm.row_version+1,updated_by=auth.uid()
  where sm.staff_id=p_staff_id and sm.row_version=p_expected_row_version and sm.active and sm.production_staff and sm.deleted_at is null returning * into v_staff;
  if not found then raise exception 'Staff member is inactive, missing or has changed. Reload before continuing.'; end if;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),case when v_immediate then 'DEACTIVATE_STAFF_MEMBER' else 'SCHEDULE_STAFF_DEACTIVATION' end,'staff_members',v_staff.staff_id::text,v_before,public.get_staff_master_record(v_staff.staff_id),trim(p_reason),coalesce(nullif(trim(p_source_application),''),'STAFF_MASTER_UI'));
  return public.get_staff_master_record(v_staff.staff_id);
end;$$;

create or replace function public.process_scheduled_staff_deactivations()
returns integer language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_count integer;
begin
  update public.staff_members set active=false,roster_eligible=false,row_version=row_version+1,updated_at=now()
  where active and deleted_at is null and deactivated_on is not null and deactivated_on<current_date;
  get diagnostics v_count=row_count;
  return v_count;
end;$$;

revoke all on function public.process_scheduled_staff_deactivations() from public,anon,authenticated;

do $$ begin
  if exists(select 1 from cron.job where jobname='staff-scheduled-deactivation') then perform cron.unschedule('staff-scheduled-deactivation'); end if;
  perform cron.schedule('staff-scheduled-deactivation','5 0 * * *',$job$select public.process_scheduled_staff_deactivations();$job$);
end $$;
