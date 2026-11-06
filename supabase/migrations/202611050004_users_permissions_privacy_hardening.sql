-- Users, permissions and privacy hardening.
--
-- 1. Accounts created outside Accounts & Access (for example through the public
--    Supabase sign-up endpoint) are no longer treated as enabled accounts. Banned
--    (disabled) or deleted accounts lose access at once, not when their token expires.
-- 2. Emails are never returned in full by the application RPCs. They are masked
--    (pa***@g***.com) wherever an email was shown or used as a fallback name.
-- 3. The General Manager review token is no longer returned to the Roster Manager
--    who sends it; only the email function (service role) can obtain it. Only an
--    Administrator can change the General Manager email.
-- 4. Internal helper functions that returned data without a permission check are no
--    longer callable by signed-in users.
-- 5. Direct table access for anon and authenticated is removed. The frontend reads and
--    writes only through RPCs and Storage, so this changes no screen. TRUNCATE (which
--    RLS does not cover) is removed with it. Future objects follow the same defaults.

-- ---------------------------------------------------------------------------
-- Email masking helpers
-- ---------------------------------------------------------------------------
create or replace function public.mask_email(p_email text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
  v_local text;
  v_domain text;
  v_tld text;
begin
  if v = '' then return null; end if;
  if position('@' in v) = 0 then return p_email; end if;
  v_local := split_part(v, '@', 1);
  v_domain := split_part(v, '@', 2);
  v_tld := case when position('.' in v_domain) > 0 then '.' || regexp_replace(v_domain, '^.*\.', '') else '' end;
  return left(v_local, case when length(v_local) <= 3 then 1 else 2 end) || '***@'
      || left(v_domain, 1) || '***' || v_tld;
end;
$$;

create or replace function public.mask_emails_in_text(p_text text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v text := p_text;
  m text;
begin
  if v is null or position('@' in v) = 0 then return v; end if;
  for m in
    select distinct x[1]
    from regexp_matches(p_text, '[A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'g') as x
    order by 1 desc
  loop
    v := replace(v, m, public.mask_email(m));
  end loop;
  return v;
end;
$$;

create or replace function public.mask_emails_in_jsonb(p_value jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
  select case when p_value is null then null else public.mask_emails_in_text(p_value::text)::jsonb end;
$$;

revoke all on function public.mask_email(text) from public, anon;
revoke all on function public.mask_emails_in_text(text) from public, anon;
revoke all on function public.mask_emails_in_jsonb(jsonb) from public, anon;
grant execute on function public.mask_email(text) to authenticated, service_role;
grant execute on function public.mask_emails_in_text(text) to authenticated, service_role;
grant execute on function public.mask_emails_in_jsonb(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enabled account: needs an Accounts & Access profile, a linked active staff record
-- or an active production terminal, and must not be banned or deleted.
-- ---------------------------------------------------------------------------
create or replace function public.current_account_is_enabled()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid() is not null
    and exists (
      select 1 from auth.users u
      where u.id = auth.uid()
        and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= now())
    )
    and case
      when exists (select 1 from public.production_station_devices d where d.device_auth_user_id = auth.uid() and d.active) then true
      when exists (select 1 from public.staff_members linked where linked.auth_user_id = auth.uid() and linked.deleted_at is null)
        then exists (
          select 1 from public.staff_members active_staff
          where active_staff.auth_user_id = auth.uid()
            and active_staff.active
            and active_staff.deleted_at is null
            and (active_staff.deactivated_on is null or active_staff.deactivated_on >= current_date)
        )
      when exists (select 1 from public.account_access_profiles ap where ap.auth_user_id = auth.uid() and ap.account_type = 'USER') then true
      else false
    end;
$$;

-- ---------------------------------------------------------------------------
-- Holiday governance: masked settings for the screen.
-- ---------------------------------------------------------------------------
create or replace function public.production_roster_leave_governance_settings_public()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select s || jsonb_build_object(
    'general_manager_email', coalesce(public.mask_email(nullif(s ->> 'general_manager_email', '')), ''),
    'general_manager_email_configured', coalesce(s ->> 'general_manager_email', '') <> ''
  )
  from (select public.production_roster_leave_governance_settings_value() as s) x;
$$;

revoke all on function public.production_roster_leave_governance_settings_public() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- General Manager review token: issued only to the email Edge Function.
-- ---------------------------------------------------------------------------
create or replace function public.issue_production_roster_gm_review_token(p_leave_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_request public.production_roster_leave_requests%rowtype;
  v_token text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'Only the email service can issue a General Manager review token.';
  end if;

  select * into v_gm
  from public.production_roster_leave_gm_reviews
  where leave_request_id = p_leave_request_id
  for update;
  if not found or v_gm.state <> 'SENDING' then
    raise exception using errcode = '55000', message = 'Prepare the General Manager review before sending it.';
  end if;
  if v_gm.expires_at is not null and v_gm.expires_at < now() then
    raise exception using errcode = '55000', message = 'This General Manager review has expired. Prepare it again.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = p_leave_request_id;
  if not found or v_request.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'Only pending requests can be sent to the General Manager.';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  update public.production_roster_leave_gm_reviews
  set token_hash = public.production_roster_leave_gm_token_hash(v_token),
      token_hint = left(v_token, 4) || '…' || right(v_token, 4),
      updated_at = now()
  where leave_request_id = p_leave_request_id;

  return jsonb_build_object(
    'leave_request_id', p_leave_request_id,
    'review_token', v_token,
    'sent_to', v_gm.sent_to,
    'expires_at', v_gm.expires_at
  );
end;
$$;

revoke all on function public.issue_production_roster_gm_review_token(uuid) from public, anon, authenticated;
grant execute on function public.issue_production_roster_gm_review_token(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Functions that returned emails, or used them as names
-- ---------------------------------------------------------------------------
-- production_roster_actor_name
CREATE OR REPLACE FUNCTION public.production_roster_actor_name(p_auth_user_id uuid, p_staff_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select coalesce(
    (select nullif(trim(ap.display_name), '') from public.account_access_profiles ap where p_auth_user_id is not null and ap.auth_user_id = p_auth_user_id),
    (select sm.display_name from public.staff_members sm where p_auth_user_id is not null and sm.auth_user_id = p_auth_user_id and sm.deleted_at is null order by sm.active desc limit 1),
    (select sm.display_name from public.staff_members sm where p_staff_id is not null and sm.staff_id = p_staff_id),
    (select public.mask_email(u.email::text) from auth.users u where p_auth_user_id is not null and u.id = p_auth_user_id)
  );
$function$;

-- customer_service_user_name
CREATE OR REPLACE FUNCTION public.customer_service_user_name(p_auth_user_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select coalesce(
    (select nullif(trim(ap.display_name),'') from public.account_access_profiles ap where ap.auth_user_id=p_auth_user_id),
    (select sm.display_name from public.staff_members sm where sm.auth_user_id=p_auth_user_id and sm.deleted_at is null order by sm.active desc limit 1),
    (select public.mask_email(u.email) from auth.users u where u.id=p_auth_user_id));
$function$;

-- stock_actor_name
CREATE OR REPLACE FUNCTION public.stock_actor_name()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select coalesce(ap.display_name,sm.display_name,public.mask_email(u.email),'Account')
  from auth.users u
  left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
  where u.id=auth.uid()
$function$;

-- company_document_audience
CREATE OR REPLACE FUNCTION public.company_document_audience()
 RETURNS TABLE(auth_user_id uuid, display_name text, employee_code text, job_title_name text, areas text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select u.id,
         coalesce(ap.display_name,sm.display_name,public.mask_email(u.email),'Account'),
         sm.employee_code,
         coalesce(jt.job_title_name,case when ap.auth_user_id is null then 'Staff' else null end),
         public.company_document_person_areas(u.id)
  from auth.users u
  left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
  where u.deleted_at is null
    and (u.banned_until is null or u.banned_until<now())
    and (ap.account_type='USER' or (ap.auth_user_id is null and sm.staff_id is not null))
    and not exists(select 1 from public.production_station_devices d where d.device_auth_user_id=u.id)
    and (sm.staff_id is null or (sm.active and (sm.deactivated_on is null or sm.deactivated_on>=current_date)))
$function$;

-- driver_role_transfer_json
CREATE OR REPLACE FUNCTION public.driver_role_transfer_json(p_transfer_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'transfer_id', t.transfer_id,
    'transfer_status', t.transfer_status,
    'driver_id', t.driver_id,
    'driver_code', d.driver_code,
    'driver_name', d.display_name,
    'driver_joined_on', d.joined_on,
    'staff_id', coalesce(t.staff_id, d.staff_id),
    'staff_employee_code', sm.employee_code,
    'staff_display_name', sm.display_name,
    'has_login', sm.auth_user_id is not null,
    'last_driver_day', t.last_driver_day,
    'effective_on', t.last_driver_day + 1,
    'job_title_code', t.job_title_code,
    'job_title_name', jt.job_title_name,
    'production_job_title', public.job_title_keeps_production_roster(t.job_title_code),
    'reason', t.reason,
    'primary_role_code', opr.role_code,
    'primary_role_name', opr.role_name,
    'default_area_code', a.area_code,
    'default_area_name', a.area_name,
    'default_station_code', st.station_code,
    'default_station_name', st.station_name,
    'default_shift_code', sh.shift_code,
    'default_shift_name', sh.shift_name,
    'roster_eligible', t.roster_eligible,
    'requested_at', t.requested_at,
    'requested_by_name', coalesce(rp.display_name, public.mask_email(rq.email)),
    'decided_at', t.decided_at,
    'decided_by_name', coalesce(dp.display_name, public.mask_email(dq.email)),
    'decision_note', t.decision_note,
    'cancelled_at', t.cancelled_at,
    'cancel_reason', t.cancel_reason,
    'applied_at', t.applied_at,
    'account_job_title_updated', t.account_job_title_updated,
    'row_version', t.row_version
  )
  from public.distribution_driver_role_transfers t
  join public.distribution_drivers d on d.driver_id = t.driver_id
  join public.account_job_titles jt on jt.job_title_code = t.job_title_code
  left join public.staff_members sm on sm.staff_id = coalesce(t.staff_id, d.staff_id)
  left join public.operational_roles opr on opr.operational_role_id = t.primary_operational_role_id
  left join public.areas a on a.area_id = t.default_area_id
  left join public.stations st on st.station_id = t.default_station_id
  left join public.shifts sh on sh.shift_id = t.default_shift_id
  left join public.account_access_profiles rp on rp.auth_user_id = t.requested_by
  left join auth.users rq on rq.id = t.requested_by
  left join public.account_access_profiles dp on dp.auth_user_id = t.decided_by
  left join auth.users dq on dq.id = t.decided_by
  where t.transfer_id = p_transfer_id
$function$;

-- get_admin_account_access_directory
CREATE OR REPLACE FUNCTION public.get_admin_account_access_directory(p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
  'auth_user_id',u.id,'email',public.mask_email(u.email),'login_method',ap.login_method,'login_identifier',ap.login_identifier,'job_title_code',ap.job_title_code,'is_active',(u.banned_until is null or u.banned_until<=now()),'created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
  'staff_id',sm.staff_id,'employee_code',sm.employee_code,'display_name',coalesce(ap.display_name,sm.display_name),'staff_active',sm.active,'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
  'role_codes',coalesce((select jsonb_agg(r.role_code order by r.role_code) from public.roles r where r.active=true and (exists(select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active) or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date))))),'[]'::jsonb),
  'permissions',coalesce((select jsonb_agg(jsonb_build_object('module_code',g.module_code,'access_scope',g.access_scope,'can_view',g.can_view,'can_create',g.can_create,'can_edit',g.can_edit,'can_approve',g.can_approve,'can_manage',g.can_manage,'effective_from',g.effective_from,'effective_until',g.effective_until) order by g.module_code) from public.account_permission_grants g where g.auth_user_id=u.id and g.active),'[]'::jsonb),
  'terminal',case when psd.station_device_id is null then null else jsonb_build_object('device_code',psd.device_code,'device_name',psd.device_name,'station_code',s.station_code,'station_name',s.station_name,'area_code',a.area_code,'active',psd.active) end
 ) order by lower(coalesce(ap.display_name,sm.display_name,u.email)),u.created_at desc)
 from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null left join public.production_station_devices psd on psd.device_auth_user_id=u.id left join public.stations s on s.station_id=psd.station_id left join public.areas a on a.area_id=s.area_id
 where (v_scope='ALL' or ap.auth_user_id=auth.uid() or jt.department_scope=v_scope)
   and (v_search is null or lower(coalesce(u.email,'')) = v_search or lower(coalesce(ap.display_name,sm.display_name,'')) like '%'||v_search||'%' or lower(coalesce(sm.employee_code,'')) like '%'||v_search||'%')),'[]'::jsonb)
 );
end;$function$;

-- get_company_document_history
CREATE OR REPLACE FUNCTION public.get_company_document_history(p_document_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if not (public.can_manage_company_documents() or public.can_view_company_document_status()) then raise exception using errcode='42501',message='Company Documents access is required.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('recorded_by_name',(select coalesce(ap.display_name,public.mask_email(u.email)) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=h.recorded_by)) order by h.recorded_at desc,h.history_id desc)
    from public.company_document_history h where h.document_id=p_document_id),'[]'::jsonb);
end;$function$;

-- get_company_documents_admin
CREATE OR REPLACE FUNCTION public.get_company_documents_admin()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v_manage boolean:=public.can_manage_company_documents();
begin
  if not (v_manage or public.can_view_company_document_status()) then raise exception using errcode='42501',message='Company Documents access is required.'; end if;
  return (with people as materialized (select * from public.company_document_audience())
  select jsonb_build_object(
    'can_manage',v_manage,
    'people',coalesce((select jsonb_agg(to_jsonb(a) order by a.display_name) from people a),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object(
        'areas',to_jsonb(public.company_document_area_codes(d.document_id)),
        'updated_by_name',(select coalesce(ap.display_name,public.mask_email(u.email)) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=d.version_published_by)
      ) order by d.category,d.title) from public.company_documents d where d.document_status<>'DELETED'),'[]'::jsonb),
    -- One row per person who must read each active document (only the people
    -- of the document's areas).
    'statuses',coalesce((select jsonb_agg(jsonb_build_object('document_id',d.document_id,'auth_user_id',a.auth_user_id) || public.company_document_person_status(d,a.auth_user_id))
        from public.company_documents d cross join people a
        where d.document_status='ACTIVE' and public.company_document_for_areas(d.document_id,a.areas)),'[]'::jsonb),
    'orphan_paths',case when v_manage then coalesce((select jsonb_agg(o.name) from storage.objects o
        where o.bucket_id='company-documents' and o.created_at<now()-interval '1 hour'
          and not exists(select 1 from public.company_documents d where d.storage_path=o.name)),'[]'::jsonb) else '[]'::jsonb end
  ));
end;$function$;

-- get_current_account_access
CREATE OR REPLACE FUNCTION public.get_current_account_access()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'account_enabled',public.current_account_is_enabled(),
    'display_name',coalesce(ap.display_name,sm.display_name,public.mask_email(u.email),'Signed in'),
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
$function$;

-- get_distribution_activity_history
CREATE OR REPLACE FUNCTION public.get_distribution_activity_history(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 250)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_from date := coalesce(p_from, current_date - 90);
  v_to date := coalesce(p_to, current_date + 30);
  v_limit integer := least(greatest(coalesce(p_limit, 250), 1), 500);
  v_keys text[] := array['display_name','phone','email','licence_number','licence_categories','licence_expires_on','cpc_expires_on','employment_status','availability_status','deactivated_on','deactivation_reason','notes'];
begin
  perform public.require_distribution_read_access();
  return jsonb_build_object(
    'range_from', v_from,
    'range_to', v_to,
    'events', coalesce((
      select jsonb_agg(
        public.mask_emails_in_jsonb(to_jsonb(x)) || jsonb_build_object(
          'recorded_by_name', coalesce(ap.display_name, sm.display_name, public.mask_email(au.email), case when x.recorded_by is null then 'System' else 'Account user' end)
        ) order by x.event_at desc
      )
      from (
        select 'Roster'::text as source,e.event_type,e.event_at,e.recorded_by,rv.week_start,rv.version_number,rv.roster_status,
          case when e.event_type='DRAFT_CREATED' then format('Week %s draft created',rv.week_start)
               when e.event_type='DRAFT_SAVED' then format('Week %s draft saved with %s entries',rv.week_start,coalesce(e.event_payload->>'entry_count','0'))
               when e.event_type='PUBLISHED' then format('Week %s published as version %s',rv.week_start,rv.version_number)
               else format('Roster week %s: %s',rv.week_start,e.event_type) end as summary
        from public.distribution_roster_events e join public.distribution_roster_versions rv on rv.distribution_roster_version_id=e.distribution_roster_version_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Daily route',e.event_type,e.event_at,e.recorded_by,r.business_date,null::integer,r.run_status,
          format('%s on %s: %s',coalesce(dr.display_name,dr.route_code,'Route'),r.business_date,e.event_type)
        from public.distribution_run_events e join public.distribution_route_runs r on r.run_id=e.run_id left join public.distribution_routes dr on dr.route_id=r.route_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Actual hours','HOURS_SAVED',a.updated_at,a.updated_by,a.week_start,null::integer,'ACTUALS',
          format('%s: %s actual hours, planned %s',d.display_name,a.actual_hours,a.planned_hours)
        from public.distribution_driver_weekly_actuals a join public.distribution_drivers d on d.driver_id=a.driver_id
        where a.updated_at::date between v_from and v_to
        union all
        select 'Vehicle mileage','MILEAGE_SAVED',m.updated_at,m.updated_by,m.week_start,null::integer,'MILEAGE',
          format('%s: %s actual KM, odometer %s',v.registration_number,m.actual_km,coalesce(m.odometer_km::text,'not recorded'))
        from public.distribution_vehicle_weekly_mileage m join public.fleet_vehicles v on v.vehicle_id=m.vehicle_id
        where m.updated_at::date between v_from and v_to
        union all
        select
          case e.entity_table when 'distribution_drivers' then 'Driver records' when 'distribution_driver_absences' then 'Driver leave' when 'distribution_driver_infringements' then 'Driver infringements' when 'fleet_vehicles' then 'Fleet records' when 'distribution_routes' then 'Route records' else 'Master data' end,
          case when e.entity_table='distribution_driver_infringements' and e.event_payload->'old'->>'status'='ACTIVE' and e.event_payload->'new'->>'status'='CANCELLED' then 'CANCELLED' else e.event_type end,
          e.event_at,e.recorded_by,null::date,null::integer,e.entity_table,
          case
            when e.entity_table='distribution_drivers' then
              format('%s (%s)%s',
                coalesce(e.event_payload->'new'->>'display_name',e.event_payload->'old'->>'display_name','Driver'),
                coalesce(e.event_payload->'new'->>'driver_code',e.event_payload->'old'->>'driver_code','No code'),
                case when e.event_type='UPDATE' then ': ' || coalesce((
                  select string_agg(format('%s: %s -> %s',
                    case k when 'display_name' then 'Name' when 'phone' then 'Phone' when 'email' then 'Email' when 'licence_number' then 'Licence number' when 'licence_categories' then 'Licence type' when 'licence_expires_on' then 'Licence expiry' when 'cpc_expires_on' then 'CPC expiry' when 'employment_status' then 'Employment' when 'availability_status' then 'Availability' when 'deactivated_on' then 'Last working day' when 'deactivation_reason' then 'Exit reason' when 'notes' then 'Notes' else k end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'old'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'old'->k)::text),'null'),'Not set') end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'new'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'new'->k)::text),'null'),'Not set') end
                  ),'; ' order by array_position(v_keys,k))
                  from unnest(v_keys) k
                  where e.event_payload->'old'->k is distinct from e.event_payload->'new'->k
                ),'Record saved') else '' end)
            when e.entity_table='distribution_driver_absences' then
              format('%s leave: %s to %s',coalesce(d.display_name,'Driver'),coalesce(e.event_payload->'new'->>'starts_on',e.event_payload->'old'->>'starts_on',''),coalesce(e.event_payload->'new'->>'ends_on',e.event_payload->'old'->>'ends_on',''))
            when e.entity_table='distribution_driver_infringements' then
              format('%s: %s · %s · happened %s%s',
                coalesce(d.display_name,'Driver'),
                case coalesce(e.event_payload->'new'->>'severity_level',e.event_payload->'old'->>'severity_level')
                  when 'NO_SEVERITY' then 'No severity' when 'MINOR' then 'Minor infringement' when 'SERIOUS' then 'Serious infringement'
                  when 'VERY_SERIOUS' then 'Very serious infringement' when 'MOST_SERIOUS' then 'Most serious infringement' else 'Infringement' end,
                coalesce(e.event_payload->'new'->>'infringement_type',e.event_payload->'old'->>'infringement_type',''),
                to_char((coalesce(e.event_payload->'new'->>'occurred_at',e.event_payload->'old'->>'occurred_at'))::timestamptz at time zone 'Europe/Dublin','DD/MM/YYYY HH24:MI'),
                case when e.event_payload->'new'->>'status'='CANCELLED' and e.event_payload->'old'->>'status'='ACTIVE' then ' · cancelled: ' || coalesce(e.event_payload->'new'->>'cancel_reason','')
                     when e.event_type='UPDATE' then ' · edited'
                     else '' end)
            when e.entity_table='fleet_vehicles' then format('Vehicle %s',coalesce(e.event_payload->'new'->>'registration_number',e.event_payload->'old'->>'registration_number','updated'))
            when e.entity_table='distribution_routes' then format('Route %s',coalesce(e.event_payload->'new'->>'route_code',e.event_payload->'old'->>'route_code','updated'))
            else format('%s %s',replace(e.entity_table,'_',' '),lower(e.event_type))
          end
        from public.distribution_master_events e
        left join public.distribution_drivers d on d.driver_id::text=coalesce(e.event_payload->'new'->>'driver_id',e.event_payload->'old'->>'driver_id')
        where e.event_at::date between v_from and v_to
        order by event_at desc
        limit v_limit
      ) x
      left join public.account_access_profiles ap on ap.auth_user_id=x.recorded_by
      left join public.staff_members sm on sm.auth_user_id=x.recorded_by
      left join auth.users au on au.id=x.recorded_by
    ),'[]'::jsonb),
    'roster_versions',coalesce((
      select jsonb_agg(to_jsonb(rv) || jsonb_build_object('created_by_name',coalesce(ap.display_name,sm.display_name,public.mask_email(au.email),'System')) order by rv.week_start desc,rv.version_number desc)
      from public.distribution_roster_versions rv
      left join public.account_access_profiles ap on ap.auth_user_id=rv.created_by
      left join public.staff_members sm on sm.auth_user_id=rv.created_by
      left join auth.users au on au.id=rv.created_by
      where rv.created_at::date between v_from and v_to or coalesce(rv.published_at,rv.created_at)::date between v_from and v_to
      limit v_limit
    ),'[]'::jsonb)
  );
end;
$function$;

-- get_sent_staff_notices
CREATE OR REPLACE FUNCTION public.get_sent_staff_notices()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v jsonb; m boolean; h integer;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 select count(*) into h from public.staff_notice_sender_preferences where auth_user_id=auth.uid() and hidden_at is not null;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into v from(
  select n.notice_id,n.title,n.message,n.notice_type,n.acknowledgement_required,n.created_at,n.expires_at,coalesce(p.display_name,public.mask_email(u.email),'System user') created_by,
   count(r.*)::int recipient_count,count(*) filter(where r.read_at is not null)::int read_count,count(*) filter(where r.acknowledged_at is not null)::int acknowledged_count,count(*) filter(where r.read_at is null)::int unopened_count
  from public.staff_notices n join public.staff_notice_recipients r using(notice_id) left join public.account_access_profiles p on p.auth_user_id=n.created_by_auth_user_id left join auth.users u on u.id=n.created_by_auth_user_id
  left join public.staff_notice_sender_preferences sp on sp.notice_id=n.notice_id and sp.auth_user_id=auth.uid() and sp.hidden_at is not null
  where (m or n.created_by_auth_user_id=auth.uid()) and sp.notice_id is null group by n.notice_id,p.display_name,u.email order by n.created_at desc limit 50
 )x; return jsonb_build_object('items',v,'can_manage_all',m,'hidden_count',h); end; $function$;

-- get_staff_notice_receipts
CREATE OR REPLACE FUNCTION public.get_staff_notice_receipts(p_notice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v jsonb; n public.staff_notices; m boolean;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','CREATE',null) then raise exception using errcode='42501',message='You cannot manage staff notices.'; end if;
 select * into n from public.staff_notices where notice_id=p_notice_id; m:=public.has_account_permission('NOTIFICATIONS','MANAGE',null);
 if n.notice_id is null or (not m and n.created_by_auth_user_id<>auth.uid()) then raise exception using errcode='42501',message='You cannot view this notice.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(sm.display_name,p.display_name,public.mask_email(u.email)),'employee_code',sm.employee_code,'read_at',r.read_at,'acknowledged_at',r.acknowledged_at,'status',case when r.acknowledged_at is not null then 'ACKNOWLEDGED' when r.read_at is not null then case when n.acknowledgement_required then 'AWAITING_ACKNOWLEDGEMENT' else 'READ' end else 'NOT_OPENED' end) order by coalesce(sm.display_name,p.display_name,u.email)),'[]') into v
 from public.staff_notice_recipients r left join public.staff_members sm on sm.auth_user_id=r.auth_user_id left join public.account_access_profiles p on p.auth_user_id=r.auth_user_id left join auth.users u on u.id=r.auth_user_id where r.notice_id=p_notice_id;
 return jsonb_build_object('notice_id',p_notice_id,'items',v); end; $function$;

-- stock_request_json
CREATE OR REPLACE FUNCTION public.stock_request_json(p_request stock_requests)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select to_jsonb(p_request) || jsonb_build_object(
    'staff_name',(select display_name from public.staff_members where staff_id=p_request.staff_id),
    'employee_code',(select employee_code from public.staff_members where staff_id=p_request.staff_id),
    'decided_by_name',(select coalesce(ap.display_name,public.mask_email(u.email)) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.decided_by),
    'locker_label',(select label from public.stock_lockers where locker_id=p_request.locker_id),
    'current_lockers',coalesce((select jsonb_agg(l.label order by l.label) from public.stock_lockers l
      where l.locker_status='ASSIGNED' and (l.staff_id=p_request.staff_id
        or l.driver_id in (select d.driver_id from public.distribution_drivers d where d.staff_id=p_request.staff_id and d.deleted_at is null))),'[]'::jsonb),
    'issued_by_name',(select coalesce(ap.display_name,public.mask_email(u.email)) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.issued_by),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('line_id',l.line_id,'item_id',l.item_id,'item_name',i.item_name,'category_name',c.category_name,
        'unit',i.unit,'size',l.size,'qty',l.qty,'issued_qty',l.issued_qty,'stock_qty',i.stock_qty,'size_options',i.size_options) order by l.line_id)
      from public.stock_request_lines l join public.stock_items i on i.item_id=l.item_id join public.stock_categories c on c.category_code=i.category_code
      where l.request_id=p_request.request_id),'[]'::jsonb))
$function$;

-- get_staff_driver_transfer_options
CREATE OR REPLACE FUNCTION public.get_staff_driver_transfer_options()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_staff_master_manage_role();
  perform public.require_distribution_master_access();

  return jsonb_build_object(
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'driver_id', d.driver_id,
        'driver_code', d.driver_code,
        'display_name', d.display_name,
        'phone', d.phone,
        'email', public.mask_email(d.email),
        'licence_number', d.licence_number,
        'licence_categories', d.licence_categories,
        'licence_expires_on', d.licence_expires_on,
        'cpc_expires_on', d.cpc_expires_on,
        'notes', d.notes
      ) order by lower(d.display_name))
      from public.distribution_drivers d
      where d.deleted_at is null and d.staff_id is null
    ), '[]'::jsonb)
  );
end;
$function$;

-- get_distribution_driver_master
CREATE OR REPLACE FUNCTION public.get_distribution_driver_master()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_distribution_read_access();
  return coalesce((
    select jsonb_agg(
      to_jsonb(d) || jsonb_build_object('email', public.mask_email(d.email)) || jsonb_build_object(
        'staff_display_name', sm.display_name,
        'staff_employee_code', sm.employee_code,
        'staff_active', sm.active and sm.deleted_at is null,
        'role_transfer', (
          select jsonb_build_object(
            'transfer_id', t.transfer_id,
            'transfer_status', t.transfer_status,
            'last_driver_day', t.last_driver_day,
            'job_title_code', t.job_title_code,
            'job_title_name', jt.job_title_name,
            'reason', t.reason,
            'row_version', t.row_version
          )
          from public.distribution_driver_role_transfers t
          join public.account_job_titles jt on jt.job_title_code = t.job_title_code
          where t.driver_id = d.driver_id and t.transfer_status in ('PENDING', 'APPROVED')
          limit 1
        ),
        'infringements', (
          select jsonb_build_object(
            'recorded_count', count(*) filter (where i.status = 'ACTIVE'),
            'active_count', count(*) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date),
            'highest_active_rank', max(public.distribution_infringement_severity_rank(i.severity_level)) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date),
            'last_occurred_at', max(i.occurred_at) filter (where i.status = 'ACTIVE'),
            'next_expiry_on', min(i.expires_on) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date)
          )
          from public.distribution_driver_infringements i
          where i.driver_id = d.driver_id
        )
      ) order by lower(d.display_name), d.driver_code)
    from public.distribution_drivers d
    left join public.staff_members sm on sm.staff_id = d.staff_id
    where d.deleted_at is null
  ), '[]'::jsonb);
end;
$function$;

-- get_distribution_roster_week
CREATE OR REPLACE FUNCTION public.get_distribution_roster_week(p_week_start date, p_roster_version_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_roster public.distribution_roster_versions%rowtype;
begin
  perform public.require_distribution_read_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'The Distribution roster must start on a Monday.';
  end if;
  if p_roster_version_id is not null then
    select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = p_roster_version_id and week_start = v_week_start;
  else
    select * into v_roster from public.distribution_roster_versions where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED') order by case roster_status when 'DRAFT' then 0 else 1 end, version_number desc limit 1;
  end if;
  return jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_start + 6,
    'can_manage', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'is_past', v_week_start + 6 < current_date,
    'document', case when v_roster.distribution_roster_version_id is null then null else to_jsonb(v_roster) end,
    'required_routes', coalesce(v_roster.required_routes, '{}'::jsonb),
    'routes', coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order, r.route_code) from public.distribution_routes r where r.active and r.deleted_at is null), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(to_jsonb(d) - array['email','phone','licence_number','notes'] order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status = 'ACTIVE' and (d.joined_on is null or d.joined_on <= v_week_start + 6)), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) order by v.registration_number) from public.fleet_vehicles v where v.deleted_at is null and v.active), '[]'::jsonb),
    'vehicle_blocks', coalesce((
      select jsonb_agg(jsonb_build_object('vehicle_id', b.vehicle_id, 'work_date', b.work_date, 'reason', b.reason) order by b.work_date)
      from (
        select v.vehicle_id, days.work_date, public.distribution_vehicle_block_reason(v.vehicle_id, days.work_date) as reason
        from public.fleet_vehicles v
        cross join (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date) days
        where v.deleted_at is null and v.active and days.work_date >= current_date
      ) b where b.reason is not null
    ), '[]'::jsonb),
    'absences', coalesce((select jsonb_agg(to_jsonb(a) order by a.starts_on, a.driver_id) from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and a.starts_on <= v_week_start + 6 and a.ends_on >= v_week_start), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date, e.route_code_snapshot) from public.distribution_roster_entries e where e.distribution_roster_version_id = v_roster.distribution_roster_version_id), '[]'::jsonb),
    'daily_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date),
      demand as (
        select days.work_date, count(distinct d.default_route_id)::integer as scheduled_routes, count(d.schedule_day_id)::integer as scheduled_stops
        from days left join public.customer_schedule_versions sv on sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
        left join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active and d.delivery_weekday=extract(isodow from days.work_date)::smallint and d.default_route_id is not null
        group by days.work_date
      )
      select jsonb_agg(jsonb_build_object('work_date',work_date,'scheduled_routes',scheduled_routes,'scheduled_stops',scheduled_stops) order by work_date) from demand
    ), '[]'::jsonb),
    'route_day_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date)
      select jsonb_agg(jsonb_build_object('route_id',r.route_id,'work_date',days.work_date,'stops',coalesce(s.stop_count,0),'km',r.default_km,'hours',r.default_hours) order by days.work_date,r.sort_order,r.route_code)
      from public.distribution_routes r cross join days
      left join lateral (
        select count(d.schedule_day_id)::integer as stop_count
        from public.customer_schedule_versions sv join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active
        where sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
          and d.default_route_id=r.route_id and d.delivery_weekday=extract(isodow from days.work_date)::smallint
      ) s on true
      where r.active and r.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$function$;

-- save_distribution_driver
CREATE OR REPLACE FUNCTION public.save_distribution_driver(p_driver jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_id uuid := nullif(p_driver ->> 'driver_id','')::uuid;
  v_existing public.distribution_drivers%rowtype;
  v_payload jsonb;
  v_code text;
  v_next integer;
  v_staff_id uuid;
  v_staff public.staff_members%rowtype;
  v_status text;
  v_result public.distribution_drivers%rowtype;
begin
  perform public.require_distribution_master_access();

  if v_id is not null then
    select d.* into v_existing
    from public.distribution_drivers d
    where d.driver_id = v_id and d.deleted_at is null
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'Driver was not found.';
    end if;
    if nullif(p_driver ->> 'row_version','') is not null
       and (p_driver ->> 'row_version')::integer <> v_existing.row_version then
      raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
    end if;
    v_code := v_existing.driver_code;
    v_payload := to_jsonb(v_existing) || p_driver;
    -- The driver form shows the email masked (pa***@g***.com). An unchanged masked
    -- value keeps the stored email instead of overwriting it.
    if position('*' in coalesce(p_driver ->> 'email', '')) > 0 then
      v_payload := jsonb_set(v_payload, '{email}', coalesce(to_jsonb(v_existing.email), 'null'::jsonb));
    end if;
  else
    v_payload := p_driver;
  end if;

  if position('*' in coalesce(v_payload ->> 'email', '')) > 0 then
    raise exception using errcode = '22023', message = 'Enter the full driver email address.';
  end if;

  if nullif(trim(v_payload ->> 'display_name'), '') is null then
    raise exception using errcode = '22023', message = 'Driver name is required.';
  end if;

  v_status := upper(coalesce(nullif(v_payload ->> 'employment_status',''),'ACTIVE'));
  if v_status = 'INACTIVE' and v_existing.employment_status is distinct from 'INACTIVE' then
    raise exception using errcode = '22023', message = 'Use Remove to record when a driver leaves the company.';
  end if;
  if v_existing.employment_status = 'INACTIVE' and v_status <> 'INACTIVE' then
    raise exception using errcode = '22023', message = 'Use Reinstate to bring a former driver back.';
  end if;

  v_staff_id := nullif(v_payload ->> 'staff_id','')::uuid;
  if v_staff_id is not null and v_staff_id is distinct from v_existing.staff_id then
    select sm.* into v_staff
    from public.staff_members sm
    where sm.staff_id = v_staff_id and sm.deleted_at is null;
    if not found or not v_staff.active then
      raise exception using errcode = '22023', message = 'The selected Staff record is not active.';
    end if;
    if v_staff.production_staff then
      raise exception using errcode = '22023', message = 'This person is production staff. Use Transfer to Driver in Staff Master.';
    end if;
    if exists (
      select 1 from public.distribution_drivers d
      where d.staff_id = v_staff_id and d.deleted_at is null and d.driver_id is distinct from v_id
    ) then
      raise exception using errcode = '23505', message = 'The selected Staff record is already linked to another driver.';
    end if;
  end if;

  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('distribution_driver_code'));
    select coalesce(max((regexp_match(driver_code, '^DRV-([0-9]+)$'))[1]::integer), 0) + 1
      into v_next
    from public.distribution_drivers
    where driver_code ~ '^DRV-[0-9]+$';
    v_code := 'DRV-' || lpad(v_next::text, 3, '0');
  end if;

  insert into public.distribution_drivers(
    driver_id,staff_id,driver_code,display_name,phone,email,licence_number,
    licence_categories,licence_expires_on,cpc_expires_on,employment_status,
    availability_status,notes,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),v_staff_id,v_code,
    trim(v_payload ->> 'display_name'),nullif(trim(v_payload ->> 'phone'),''),
    nullif(lower(trim(v_payload ->> 'email')),''),nullif(upper(trim(v_payload ->> 'licence_number')),''),
    coalesce(array(
      select distinct upper(trim(value))
      from jsonb_array_elements_text(coalesce(v_payload -> 'licence_categories','[]'::jsonb)) as value
      where nullif(trim(value),'') is not null
      order by 1
    ),array[]::text[]),
    nullif(v_payload ->> 'licence_expires_on','')::date,
    nullif(v_payload ->> 'cpc_expires_on','')::date,
    v_status,
    upper(coalesce(nullif(v_payload ->> 'availability_status',''),'AVAILABLE')),
    nullif(trim(v_payload ->> 'notes'),''),auth.uid(),auth.uid()
  )
  on conflict (driver_id) do update set
    staff_id=excluded.staff_id,display_name=excluded.display_name,phone=excluded.phone,
    email=excluded.email,licence_number=excluded.licence_number,
    licence_categories=excluded.licence_categories,
    licence_expires_on=excluded.licence_expires_on,cpc_expires_on=excluded.cpc_expires_on,
    employment_status=excluded.employment_status,availability_status=excluded.availability_status,
    notes=excluded.notes,updated_at=now(),updated_by=auth.uid(),
    row_version=public.distribution_drivers.row_version+1
  returning * into v_result;

  return to_jsonb(v_result) || jsonb_build_object('email', public.mask_email(v_result.email));
end;
$function$;

-- get_production_roster_gm_review
CREATE OR REPLACE FUNCTION public.get_production_roster_gm_review(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_request public.production_roster_leave_requests%rowtype;
begin
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  select * into v_gm
  from public.production_roster_leave_gm_reviews gm
  where gm.token_hash = public.production_roster_leave_gm_token_hash(trim(p_token));
  if not found then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = v_gm.leave_request_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'The Holiday request no longer exists.';
  end if;

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'display_name', v_request.staff_display_name_snapshot,
    'request_type', v_request.request_type,
    'start_date', v_request.start_date,
    'end_date', v_request.end_date,
    'duration_days', (v_request.end_date - v_request.start_date) + 1,
    'reason', public.mask_emails_in_text(v_request.reason),
    'status', v_request.status,
    'gm_state', v_gm.state,
    'gm_decision', v_gm.decision,
    'sent_to', public.mask_email(v_gm.sent_to),
    'sent_at', v_gm.sent_at,
    'expires_at', v_gm.expires_at,
    'expired', v_gm.expires_at is not null and v_gm.expires_at < now(),
    'decided_at', v_gm.decided_at,
    'decision_note', v_gm.decision_note
  );
end;
$function$;

-- decide_production_roster_gm_review
CREATE OR REPLACE FUNCTION public.decide_production_roster_gm_review(p_token text, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_decision text := upper(trim(coalesce(p_decision, '')));
  v_hash text;
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_request public.production_roster_leave_requests%rowtype;
begin
  if v_decision not in ('APPROVED', 'REJECTED') then
    raise exception using errcode = '22023', message = 'Decision must be Approved or Rejected.';
  end if;
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  v_hash := public.production_roster_leave_gm_token_hash(trim(p_token));
  select * into v_gm
  from public.production_roster_leave_gm_reviews gm
  where gm.token_hash = v_hash
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  if v_gm.state = 'DECIDED' then
    return jsonb_build_object(
      'leave_request_id', v_gm.leave_request_id,
      'status', v_gm.decision,
      'gm_state', v_gm.state,
      'message', 'This Holiday request was already ' || lower(coalesce(v_gm.decision, 'decided')) || '.'
    );
  end if;
  if v_gm.expires_at is not null and v_gm.expires_at < now() then
    raise exception using errcode = '55000', message = 'This General Manager review link has expired. Ask the Roster Manager to send a new email.';
  end if;
  if v_gm.state not in ('AWAITING_GM', 'SENDING') then
    raise exception using errcode = '55000', message = 'This General Manager review is not currently awaiting a decision.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = v_gm.leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'The Holiday request no longer exists.';
  end if;

  if v_request.status <> 'PENDING' then
    update public.production_roster_leave_gm_reviews
    set state = 'DECIDED',
        decision = v_request.status,
        decided_at = coalesce(decided_at, now()),
        decision_note = coalesce(decision_note, v_request.review_note),
        updated_at = now()
    where leave_request_id = v_request.leave_request_id;

    return jsonb_build_object(
      'leave_request_id', v_request.leave_request_id,
      'status', v_request.status,
      'gm_state', 'DECIDED',
      'message', 'This Holiday request was already ' || lower(v_request.status) || '.'
    );
  end if;

  update public.production_roster_leave_requests
  set status = v_decision,
      reviewed_at = now(),
      reviewed_by = null,
      review_note = nullif(trim(p_note), ''),
      decision_source = 'GENERAL_MANAGER',
      decision_actor = 'General Manager'
  where leave_request_id = v_request.leave_request_id
  returning * into v_request;

  update public.production_roster_leave_gm_reviews
  set state = 'DECIDED',
      decision = v_decision,
      decided_at = now(),
      decision_note = nullif(trim(p_note), ''),
      last_error = null,
      updated_at = now()
  where leave_request_id = v_request.leave_request_id
  returning * into v_gm;

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'GENERAL_MANAGER_DECISION',
    'General Manager',
    'GENERAL_MANAGER',
    'PENDING',
    v_decision,
    p_note,
    jsonb_build_object('sent_to', public.mask_email(v_gm.sent_to)),
    null
  );

  insert into public.audit_log (
    action, entity_table, entity_id, new_data, reason, source_application
  ) values (
    case when v_decision = 'APPROVED'
      then 'PRODUCTION_ROSTER_LEAVE_REQUEST_GM_APPROVED'
      else 'PRODUCTION_ROSTER_LEAVE_REQUEST_GM_REJECTED'
    end,
    'production_roster_leave_requests',
    v_request.leave_request_id::text,
    jsonb_build_object(
      'staff_id', v_request.staff_id,
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'status', v_request.status,
      'decision_source', 'GENERAL_MANAGER'
    ),
    v_request.review_note,
    'PRODUCTION_ROSTER_GM_REVIEW'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'gm_state', v_gm.state,
    'decided_at', v_gm.decided_at,
    'message', 'Holiday request ' || case when v_decision = 'APPROVED' then 'approved' else 'rejected' end || '.'
  );
end;
$function$;

-- decide_production_roster_leave_request
CREATE OR REPLACE FUNCTION public.decide_production_roster_leave_request(p_leave_request_id uuid, p_decision text, p_review_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_decision text := upper(trim(coalesce(p_decision, '')));
  v_request public.production_roster_leave_requests%rowtype;
  v_actor_staff uuid := public.current_staff_id();
  v_actor_label text := coalesce(public.production_roster_actor_name(auth.uid(), null), 'Roster manager');
  v_gm public.production_roster_leave_gm_reviews%rowtype;
begin
  perform public.require_production_roster_manage_role();

  if v_decision not in ('APPROVED', 'REJECTED') then
    raise exception using errcode = '22023', message = 'Decision must be APPROVED or REJECTED.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Leave request not found.';
  end if;
  if v_request.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'Only pending leave requests can be reviewed.';
  end if;

  select * into v_gm
  from public.production_roster_leave_gm_reviews
  where leave_request_id = p_leave_request_id;

  if found and v_gm.state in ('SENDING', 'AWAITING_GM') then
    raise exception using errcode = '55000', message = 'This Holiday is awaiting the General Manager decision.';
  end if;

  if v_decision = 'APPROVED' and v_request.requires_general_manager then
    raise exception using errcode = '55000', message = 'This Holiday requires General Manager approval. Send it to the General Manager from the Requests queue.';
  end if;

  update public.production_roster_leave_requests
  set status = v_decision,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = nullif(trim(p_review_note), ''),
      decision_source = 'MANAGER',
      decision_actor = v_actor_label
  where leave_request_id = v_request.leave_request_id
  returning * into v_request;

  if v_decision = 'REJECTED' then
    update public.production_roster_leave_gm_reviews
    set state = 'CANCELLED',
        decision = 'REJECTED',
        decided_at = now(),
        decision_note = nullif(trim(p_review_note), ''),
        updated_at = now()
    where leave_request_id = v_request.leave_request_id
      and state not in ('DECIDED', 'CANCELLED');
  end if;

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'MANAGER_DECISION',
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    v_decision,
    p_review_note,
    jsonb_build_object('decision', v_decision),
    auth.uid()
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff,
    case when v_decision = 'APPROVED' then 'PRODUCTION_ROSTER_LEAVE_REQUEST_APPROVED' else 'PRODUCTION_ROSTER_LEAVE_REQUEST_REJECTED' end,
    'production_roster_leave_requests', v_request.leave_request_id::text,
    jsonb_build_object(
      'staff_id', v_request.staff_id,
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'status', v_request.status,
      'decision_source', 'MANAGER'
    ),
    v_request.review_note,
    'PRODUCTION_ROSTER'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'reviewed_at', v_request.reviewed_at,
    'decision_source', 'MANAGER',
    'message', case when v_decision = 'APPROVED'
      then 'Request approved. The approved dates will be protected in the Roster planner and require Save/Publish when applicable.'
      else 'Request rejected.' end
  );
end;
$function$;

-- mark_production_roster_gm_email_result
CREATE OR REPLACE FUNCTION public.mark_production_roster_gm_email_result(p_leave_request_id uuid, p_success boolean, p_error_message text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_actor_label text := coalesce(public.production_roster_actor_name(auth.uid(), null), 'Roster manager');
begin
  perform public.require_production_roster_manage_role();

  select * into v_gm
  from public.production_roster_leave_gm_reviews
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'General Manager review state not found.';
  end if;

  update public.production_roster_leave_gm_reviews
  set state = case when p_success then 'AWAITING_GM' else 'SEND_FAILED' end,
      sent_at = case when p_success then now() else sent_at end,
      last_error = case when p_success then null else left(coalesce(p_error_message, 'Email delivery failed.'), 1000) end,
      updated_at = now()
  where leave_request_id = p_leave_request_id
  returning * into v_gm;

  perform public.record_production_roster_leave_event(
    p_leave_request_id,
    case when p_success then 'FORWARDED_TO_GM' else 'GM_EMAIL_SEND_FAILED' end,
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    'PENDING',
    case when p_success then null else p_error_message end,
    jsonb_build_object('sent_to', public.mask_email(v_gm.sent_to), 'expires_at', v_gm.expires_at),
    auth.uid()
  );

  return jsonb_build_object(
    'leave_request_id', p_leave_request_id,
    'gm_state', v_gm.state,
    'sent_to', public.mask_email(v_gm.sent_to),
    'sent_at', v_gm.sent_at,
    'expires_at', v_gm.expires_at
  );
end;
$function$;

-- prepare_production_roster_gm_review
CREATE OR REPLACE FUNCTION public.prepare_production_roster_gm_review(p_leave_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_request public.production_roster_leave_requests%rowtype;
  v_settings jsonb := public.production_roster_leave_governance_settings_value();
  v_email text;
  v_ttl integer;
  v_token text;
  v_expires timestamptz;
  v_actor_label text := coalesce(public.production_roster_actor_name(auth.uid(), null), 'Roster manager');
begin
  perform public.require_production_roster_manage_role();

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Leave request not found.';
  end if;
  if v_request.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'Only pending requests can be sent to the General Manager.';
  end if;
  if not v_request.requires_general_manager then
    raise exception using errcode = '55000', message = 'This Holiday does not require General Manager approval.';
  end if;

  v_email := trim(coalesce(v_settings ->> 'general_manager_email', ''));
  if v_email = '' then
    raise exception using errcode = '55000', message = 'General Manager email is not configured. Open Requests > Settings.';
  end if;
  v_ttl := greatest(24, coalesce((v_settings ->> 'general_manager_token_ttl_hours')::integer, 168));
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + make_interval(hours => v_ttl);

  insert into public.production_roster_leave_gm_reviews (
    leave_request_id, token_hash, token_hint, sent_to, state,
    sent_at, expires_at, decision, decided_at, decision_note, last_error, updated_at
  ) values (
    v_request.leave_request_id,
    public.production_roster_leave_gm_token_hash(v_token),
    left(v_token, 4) || '…' || right(v_token, 4),
    v_email,
    'SENDING',
    null,
    v_expires,
    null,
    null,
    null,
    null,
    now()
  )
  on conflict (leave_request_id) do update
  set token_hash = excluded.token_hash,
      token_hint = excluded.token_hint,
      sent_to = excluded.sent_to,
      state = 'SENDING',
      sent_at = null,
      expires_at = excluded.expires_at,
      decision = null,
      decided_at = null,
      decision_note = null,
      last_error = null,
      updated_at = now();

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'GM_EMAIL_PREPARED',
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    'PENDING',
    null,
    jsonb_build_object('sent_to', public.mask_email(v_email), 'expires_at', v_expires),
    auth.uid()
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    -- The review token is no longer returned to the signed-in Roster Manager:
    -- holding it would let them approve as the General Manager. The email
    -- function obtains it with issue_production_roster_gm_review_token (service role only).
    'sent_to', public.mask_email(v_email),
    'expires_at', v_expires,
    'display_name', v_request.staff_display_name_snapshot,
    'request_type', v_request.request_type,
    'start_date', v_request.start_date,
    'end_date', v_request.end_date,
    'duration_days', (v_request.end_date - v_request.start_date) + 1,
    'reason', v_request.reason,
    'general_manager_threshold_days', v_request.gm_threshold_days_snapshot
  );
end;
$function$;

-- record_production_roster_leave_event
CREATE OR REPLACE FUNCTION public.record_production_roster_leave_event(p_leave_request_id uuid, p_event_type text, p_actor_label text DEFAULT NULL::text, p_actor_role text DEFAULT NULL::text, p_from_status text DEFAULT NULL::text, p_to_status text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb, p_actor_auth_user_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_id uuid;
begin
  insert into public.production_roster_leave_request_events (
    leave_request_id, event_type, actor_auth_user_id, actor_label, actor_role,
    from_status, to_status, note, metadata
  ) values (
    p_leave_request_id,
    upper(trim(coalesce(p_event_type, 'EVENT'))),
    p_actor_auth_user_id,
    nullif(trim(public.mask_emails_in_text(p_actor_label)), ''),
    nullif(trim(p_actor_role), ''),
    nullif(trim(p_from_status), ''),
    nullif(trim(p_to_status), ''),
    nullif(trim(p_note), ''),
    coalesce(public.mask_emails_in_jsonb(p_metadata), '{}'::jsonb)
  ) returning leave_event_id into v_id;
  return v_id;
end;
$function$;

-- get_production_roster_leave_request_history
CREATE OR REPLACE FUNCTION public.get_production_roster_leave_request_history(p_leave_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_production_roster_manage_role();
  return public.mask_emails_in_jsonb(coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_event_id', e.leave_event_id,
      'event_type', e.event_type,
      'actor_label', public.mask_emails_in_text(e.actor_label),
      'actor_role', e.actor_role,
      'from_status', e.from_status,
      'to_status', e.to_status,
      'note', e.note,
      'metadata', public.mask_emails_in_jsonb(e.metadata),
      'occurred_at', e.occurred_at
    ) order by e.occurred_at desc, e.leave_event_id desc)
    from public.production_roster_leave_request_events e
    where e.leave_request_id = p_leave_request_id
  ), '[]'::jsonb));
end;
$function$;

-- get_production_roster_leave_dashboard
CREATE OR REPLACE FUNCTION public.get_production_roster_leave_dashboard(p_week_start date DEFAULT NULL::date, p_shift_code text DEFAULT NULL::text, p_scope text DEFAULT 'ACTION'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_current_week date := public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date);
  v_selected_week date := public.production_roster_week_start(coalesce(p_week_start, (now() at time zone 'Europe/Dublin')::date));
  v_shift_code text := upper(nullif(trim(coalesce(p_shift_code, '')), ''));
  v_scope text := upper(trim(coalesce(p_scope, 'ACTION')));
  v_requests jsonb;
  v_summary jsonb;
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if v_scope not in ('ACTION', 'UPCOMING', 'AWAITING_GM', 'HISTORY', 'ALL') then
    raise exception using errcode = '22023', message = 'Invalid leave request view.';
  end if;

  with base as (
    select
      prlr.*,
      ((prlr.end_date - prlr.start_date) + 1)::integer as duration_days,
      public.production_roster_week_start(prlr.start_date) as request_week_start,
      public.production_roster_week_start(prlr.start_date) - 7 as planning_week_start,
      public.production_roster_week_start(prlr.start_date) - 4 as decision_due_date,
      sh.shift_code as default_shift_code,
      sh.shift_name as default_shift_name,
      gm.state as gm_state,
      gm.sent_to as gm_sent_to,
      gm.sent_at as gm_sent_at,
      gm.expires_at as gm_expires_at,
      gm.decision as gm_decision,
      gm.decided_at as gm_decided_at,
      gm.updated_at as gm_updated_at,
      case
        when prlr.status <> 'PENDING' then prlr.status
        when gm.state = 'SEND_FAILED' then 'GM_SEND_FAILED'
        when gm.state = 'SENDING' then 'GM_SENDING'
        when gm.state = 'AWAITING_GM' then 'AWAITING_GM'
        when prlr.start_date = v_today then 'STARTS_TODAY'
        when (public.production_roster_week_start(prlr.start_date) - 4) < v_today then 'DECISION_OVERDUE'
        when daterange(prlr.start_date, prlr.end_date, '[]') && daterange(v_selected_week, v_selected_week + 6, '[]') then 'SELECTED_ROSTER_WEEK'
        when (public.production_roster_week_start(prlr.start_date) - 7) <= v_today then 'PLAN_THIS_WEEK'
        else 'UPCOMING'
      end as attention_state
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
  ), filtered as (
    select *
    from base b
    where (v_shift_code is null or upper(coalesce(b.default_shift_code, '')) = v_shift_code)
      and (
        v_scope = 'ALL'
        or (v_scope = 'HISTORY' and b.status <> 'PENDING')
        or (v_scope = 'AWAITING_GM' and b.status = 'PENDING' and b.gm_state in ('SENDING', 'AWAITING_GM', 'SEND_FAILED'))
        or (v_scope = 'UPCOMING' and b.status = 'PENDING' and b.attention_state = 'UPCOMING')
        or (v_scope = 'ACTION' and b.status = 'PENDING' and b.attention_state <> 'UPCOMING')
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'leave_request_id', f.leave_request_id,
    'staff_id', f.staff_id,
    'display_name', f.staff_display_name_snapshot,
    'request_type', f.request_type,
    'start_date', f.start_date,
    'end_date', f.end_date,
    'duration_days', f.duration_days,
    'reason', f.reason,
    'status', f.status,
    'submitted_at', f.submitted_at,
    'reviewed_at', f.reviewed_at,
    'review_note', f.review_note,
    'decision_source', f.decision_source,
    'decision_actor', public.mask_emails_in_text(f.decision_actor),
    'default_shift_code', f.default_shift_code,
    'default_shift_name', f.default_shift_name,
    'planning_week_start', f.planning_week_start,
    'decision_due_date', f.decision_due_date,
    'attention_state', f.attention_state,
    'requires_general_manager', f.requires_general_manager,
    'general_manager_threshold_days', f.gm_threshold_days_snapshot,
    'gm_state', f.gm_state,
    'gm_sent_to', public.mask_email(f.gm_sent_to),
    'gm_sent_at', f.gm_sent_at,
    'gm_expires_at', f.gm_expires_at,
    'gm_decision', f.gm_decision,
    'gm_decided_at', f.gm_decided_at,
    'gm_updated_at', f.gm_updated_at
  ) order by
    case f.attention_state
      when 'STARTS_TODAY' then 1
      when 'DECISION_OVERDUE' then 2
      when 'GM_SEND_FAILED' then 3
      when 'GM_SENDING' then 4
      when 'AWAITING_GM' then 5
      when 'SELECTED_ROSTER_WEEK' then 6
      when 'PLAN_THIS_WEEK' then 7
      when 'UPCOMING' then 8
      else 20
    end,
    f.start_date,
    f.submitted_at), '[]'::jsonb)
  into v_requests
  from filtered f;

  with base as (
    select
      prlr.status,
      prlr.start_date,
      prlr.end_date,
      public.production_roster_week_start(prlr.start_date) - 7 as planning_week_start,
      gm.state as gm_state,
      sh.shift_code as default_shift_code
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where (v_shift_code is null or upper(coalesce(sh.shift_code, '')) = v_shift_code)
  )
  select jsonb_build_object(
    'action_count', count(*) filter (
      where status = 'PENDING'
        and (planning_week_start <= v_today or gm_state in ('SENDING', 'AWAITING_GM', 'SEND_FAILED'))
    ),
    'selected_week_pending_count', count(*) filter (
      where status = 'PENDING'
        and daterange(start_date, end_date, '[]') && daterange(v_selected_week, v_selected_week + 6, '[]')
    ),
    'awaiting_gm_count', count(*) filter (where status = 'PENDING' and gm_state = 'AWAITING_GM'),
    'upcoming_count', count(*) filter (where status = 'PENDING' and planning_week_start > v_today and coalesce(gm_state, '') not in ('SENDING', 'AWAITING_GM', 'SEND_FAILED')),
    'approved_count', count(*) filter (where status = 'APPROVED'),
    'rejected_count', count(*) filter (where status = 'REJECTED'),
    'expired_count', count(*) filter (where status = 'EXPIRED'),
    'history_count', count(*) filter (where status <> 'PENDING')
  ) into v_summary
  from base;

  -- Free-text fields (reason, review note) can contain an email typed by someone.
  v_requests := public.mask_emails_in_jsonb(v_requests);

  return jsonb_build_object(
    'generated_at', now(),
    'today', v_today,
    'current_week_start', v_current_week,
    'selected_week_start', v_selected_week,
    'scope', v_scope,
    'settings', public.production_roster_leave_governance_settings_public(),
    'summary', coalesce(v_summary, '{}'::jsonb),
    'requests', coalesce(v_requests, '[]'::jsonb)
  );
end;
$function$;

-- search_production_roster_staff_leave_history
CREATE OR REPLACE FUNCTION public.search_production_roster_staff_leave_history(p_staff_search text DEFAULT NULL::text, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_search text := trim(coalesce(p_staff_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
  v_requests jsonb;
  v_staff jsonb;
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if length(v_search) > 120 then
    raise exception using errcode = '22023', message = 'Staff search is too long.';
  end if;

  with matched as (
    select
      prlr.*,
      ((prlr.end_date - prlr.start_date) + 1)::integer as duration_days,
      sh.shift_code as default_shift_code,
      sh.shift_name as default_shift_name,
      gm.state as gm_state,
      gm.sent_to as gm_sent_to,
      gm.sent_at as gm_sent_at,
      gm.expires_at as gm_expires_at,
      gm.decision as gm_decision,
      gm.decided_at as gm_decided_at,
      gm.updated_at as gm_updated_at
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where v_search = ''
       or prlr.staff_display_name_snapshot ilike '%' || v_search || '%'
       or coalesce(sm.display_name, '') ilike '%' || v_search || '%'
    order by prlr.submitted_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'leave_request_id', m.leave_request_id,
    'staff_id', m.staff_id,
    'display_name', m.staff_display_name_snapshot,
    'request_type', m.request_type,
    'start_date', m.start_date,
    'end_date', m.end_date,
    'duration_days', m.duration_days,
    'reason', m.reason,
    'status', m.status,
    'submitted_at', m.submitted_at,
    'reviewed_at', m.reviewed_at,
    'review_note', m.review_note,
    'requires_general_manager', m.requires_general_manager,
    'general_manager_threshold_days', coalesce(m.gm_threshold_days_snapshot, 20),
    'decision_source', m.decision_source,
    'decision_actor', public.mask_emails_in_text(m.decision_actor),
    'default_shift_code', m.default_shift_code,
    'default_shift_name', m.default_shift_name,
    'gm_state', m.gm_state,
    'gm_sent_to', public.mask_email(m.gm_sent_to),
    'gm_sent_at', m.gm_sent_at,
    'gm_expires_at', m.gm_expires_at,
    'gm_decision', m.gm_decision,
    'gm_decided_at', m.gm_decided_at,
    'gm_updated_at', m.gm_updated_at,
    'attention_state', case when m.status = 'PENDING' then 'PENDING' else m.status end
  ) order by m.submitted_at desc), '[]'::jsonb)
  into v_requests
  from matched m;

  with staff_summary as (
    select
      prlr.staff_id,
      max(coalesce(sm.display_name, prlr.staff_display_name_snapshot)) as display_name,
      count(*)::integer as total_requests,
      count(*) filter (where prlr.status = 'PENDING')::integer as pending_count,
      count(*) filter (where prlr.status = 'APPROVED')::integer as approved_count,
      count(*) filter (where prlr.status = 'REJECTED')::integer as rejected_count,
      count(*) filter (where prlr.status = 'EXPIRED')::integer as expired_count,
      count(*) filter (where prlr.status = 'CANCELLED')::integer as cancelled_count,
      max(prlr.submitted_at) as last_request_at
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    where v_search = ''
       or prlr.staff_display_name_snapshot ilike '%' || v_search || '%'
       or coalesce(sm.display_name, '') ilike '%' || v_search || '%'
    group by prlr.staff_id
    order by max(prlr.submitted_at) desc, max(prlr.staff_display_name_snapshot)
    limit 50
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id', s.staff_id,
    'display_name', s.display_name,
    'total_requests', s.total_requests,
    'pending_count', s.pending_count,
    'approved_count', s.approved_count,
    'rejected_count', s.rejected_count,
    'expired_count', s.expired_count,
    'cancelled_count', s.cancelled_count,
    'last_request_at', s.last_request_at
  ) order by s.last_request_at desc, s.display_name), '[]'::jsonb)
  into v_staff
  from staff_summary s;

  v_requests := public.mask_emails_in_jsonb(v_requests);
  v_staff := public.mask_emails_in_jsonb(v_staff);

  return jsonb_build_object(
    'query', v_search,
    'staff', v_staff,
    'requests', v_requests,
    'limit', v_limit
  );
end;
$function$;

-- get_production_roster_leave_requests
CREATE OR REPLACE FUNCTION public.get_production_roster_leave_requests(p_status text DEFAULT 'PENDING'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_status text := upper(nullif(trim(coalesce(p_status, '')), ''));
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if v_status is not null and v_status not in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED', 'EXPIRED') then
    raise exception using errcode = '22023', message = 'Invalid leave request status.';
  end if;

  return public.mask_emails_in_jsonb(coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_request_id', prlr.leave_request_id,
      'staff_id', prlr.staff_id,
      'display_name', prlr.staff_display_name_snapshot,
      'request_type', prlr.request_type,
      'start_date', prlr.start_date,
      'end_date', prlr.end_date,
      'duration_days', (prlr.end_date - prlr.start_date) + 1,
      'reason', prlr.reason,
      'status', prlr.status,
      'submitted_at', prlr.submitted_at,
      'reviewed_at', prlr.reviewed_at,
      'review_note', prlr.review_note,
      'decision_source', prlr.decision_source,
      'decision_actor', public.mask_emails_in_text(prlr.decision_actor),
      'requires_general_manager', prlr.requires_general_manager,
      'general_manager_threshold_days', prlr.gm_threshold_days_snapshot,
      'gm_state', gm.state,
      'gm_decision', gm.decision,
      'default_shift_code', sh.shift_code,
      'default_shift_name', sh.shift_name
    ) order by prlr.start_date, prlr.submitted_at)
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where v_status is null or prlr.status = v_status
  ), '[]'::jsonb));
end;
$function$;

-- get_production_roster_leave_governance_settings
CREATE OR REPLACE FUNCTION public.get_production_roster_leave_governance_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_production_roster_manage_role();
  return public.production_roster_leave_governance_settings_public();
end;
$function$;

-- save_production_roster_leave_governance_settings
CREATE OR REPLACE FUNCTION public.save_production_roster_leave_governance_settings(p_general_manager_threshold_days integer, p_general_manager_email text, p_general_manager_token_ttl_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_threshold integer := greatest(1, least(120, coalesce(p_general_manager_threshold_days, 20)));
  v_email text := trim(coalesce(p_general_manager_email, ''));
  v_ttl integer := greatest(24, least(720, coalesce(p_general_manager_token_ttl_hours, 168)));
  v_actor_staff uuid := public.current_staff_id();
  v_current_email text := trim(coalesce(public.production_roster_leave_governance_settings_value() ->> 'general_manager_email', ''));
begin
  perform public.require_production_roster_manage_role();

  -- The settings form shows the stored email masked. An unchanged masked value keeps it.
  if position('*' in v_email) > 0 then
    v_email := v_current_email;
  end if;
  -- Whoever controls this address can approve long Holidays as the General Manager,
  -- so only an Administrator may change it.
  if lower(v_email) is distinct from lower(v_current_email) and not public.has_any_role(array['ADMIN']) then
    raise exception using errcode = '42501', message = 'Only an Administrator can change the General Manager email.';
  end if;

  if v_email <> '' and v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'Enter a valid General Manager email address.';
  end if;

  insert into public.app_config (config_key, value_json, description, updated_by)
  values (
    'PRODUCTION_ROSTER_LEAVE_GOVERNANCE',
    jsonb_build_object(
      'general_manager_threshold_days', v_threshold,
      'general_manager_email', v_email,
      'general_manager_token_ttl_hours', v_ttl
    ),
    'Production Roster Holiday / Day Off governance. Holidays longer than the threshold require General Manager approval.',
    auth.uid()
  )
  on conflict (config_key) do update
  set value_json = excluded.value_json,
      description = excluded.description,
      updated_at = now(),
      updated_by = auth.uid();

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE_UPDATED',
    'app_config', 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE',
    jsonb_build_object(
      'general_manager_threshold_days', v_threshold,
      'general_manager_email_configured', v_email <> '',
      'general_manager_token_ttl_hours', v_ttl
    ),
    'PRODUCTION_ROSTER'
  );

  return public.production_roster_leave_governance_settings_public();
end;
$function$;

-- ---------------------------------------------------------------------------
-- Internal helpers that returned data without a permission check. They are only
-- called from SECURITY DEFINER functions, which run as the owner.
-- ---------------------------------------------------------------------------
revoke execute on function public.finish_rewash_customer_options_v1(date) from public, anon, authenticated;
revoke execute on function public.sorting_schedule_product_snapshot(uuid, text, date) from public, anon, authenticated;
revoke execute on function public.finish_assert_entry_open(uuid, timestamp with time zone) from public, anon, authenticated;
revoke execute on function public.production_station_device_context(text) from public, anon, authenticated;
revoke execute on function public.customer_delivery_date(uuid, date) from public, anon, authenticated;
revoke execute on function public.schedule_delivery_date(uuid, date) from public, anon, authenticated;
revoke execute on function public.prevent_duplicate_sorting_trolley_intake_4h() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- No direct table access from the browser. Everything goes through RPCs.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon;
alter default privileges for role postgres revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Staff Master "Transfer to Driver" reuses an existing driver's email, which the
-- screen now receives masked. A masked value keeps the stored email.
-- ---------------------------------------------------------------------------
do $transfer$
declare
  d text := pg_get_functiondef('public.transfer_staff_to_distribution_driver(uuid,integer,uuid,text,text,text,text,text[],date,date,text,text,text,date)'::regprocedure);
  v_update constant text := $q$email=nullif(trim(p_email),''),$q$;
  v_insert constant text := $q$trim(p_phone),nullif(trim(p_email),''),$q$;
begin
  if (length(d) - length(replace(d, v_update, ''))) / length(v_update) <> 1
     or (length(d) - length(replace(d, v_insert, ''))) / length(v_insert) <> 1 then
    raise exception 'transfer_staff_to_distribution_driver changed; review this patch.';
  end if;
  d := replace(d, v_update, $q$email=case when position('*' in coalesce(p_email,''))>0 then email else nullif(trim(p_email),'') end,$q$);
  d := replace(d, v_insert, $q$trim(p_phone),case when position('*' in coalesce(p_email,''))>0 then null else nullif(trim(p_email),'') end,$q$);
  execute d;
end
$transfer$;
