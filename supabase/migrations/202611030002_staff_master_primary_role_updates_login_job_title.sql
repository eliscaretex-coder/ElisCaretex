-- Staff Master primary role change also changes the person's login job title.
--
-- Owner report 2026-11-01: a staff member was changed in Staff Master from
-- General Operative to Production Manager. Staff Master showed Production
-- Manager, but the person kept working as a General Operative everywhere else.
--
-- Cause: Staff Master saves the primary role in staff_members. The pages,
-- menus and permissions follow the login job title in account_access_profiles
-- (with its account_permission_grants and account_roles). Nothing copied the
-- new primary role to the login, so the two drifted apart.
--
-- Now, when update_staff_master_with_current_roster_role changes the primary
-- role of a staff member who has a personal login:
-- * The login gets the matching job title with that job title's standard
--   permissions (public.apply_account_job_title_template, the same result as
--   choosing that job title in Accounts & access):
--     PRODUCTION_MANAGER -> PRODUCTION_MANAGER   SUPERVISOR -> PRODUCTION_SUPERVISOR
--     TEAM_LEADER -> TEAM_LEADER                 LABEL -> LABEL_OPERATIVE
--     GENERAL_OPERATIVE -> GENERAL_OPERATIVE     CLEANER -> CLEANER
--     MAINTENANCE -> MAINTENANCE
--   SUPPORT_ROLE has no job title and DRIVER moves through the Driver
--   transfer, so those two leave the login unchanged.
-- * Only a login whose job title is one of those Production job titles
--   follows. A login with another job title (Administrator, General Manager,
--   Logistics Manager, Auditor, Customer Service, Driver...) was set on
--   purpose in Accounts & access and is left alone.
-- * Hierarchy: the person saving must rank above both the current and the new
--   job title (an Administrator always can). Otherwise the save is refused
--   with a clear message, so Staff Master and the login never disagree again.
--   Example: a Production Supervisor can make a General Operative a Team
--   Leader, but cannot make anyone a Production Supervisor or Production
--   Manager.
-- * The change is written to audit_log (SYNC_LOGIN_JOB_TITLE_FROM_STAFF_MASTER).
--
-- Repair: logins with a Production job title that disagrees with the Staff
-- Master primary role get the job title of the primary role (on 2026-11-03
-- this is one account: EMP-00002, Production Manager in Staff Master, General
-- Operative on the login).

begin;

-- 1. Login job title for a Staff Master primary role (null = no automatic job title).
create or replace function public.job_title_for_primary_role(p_role_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case upper(trim(coalesce(p_role_code, '')))
    when 'PRODUCTION_MANAGER' then 'PRODUCTION_MANAGER'
    when 'SUPERVISOR' then 'PRODUCTION_SUPERVISOR'
    when 'TEAM_LEADER' then 'TEAM_LEADER'
    when 'LABEL' then 'LABEL_OPERATIVE'
    when 'GENERAL_OPERATIVE' then 'GENERAL_OPERATIVE'
    when 'CLEANER' then 'CLEANER'
    when 'MAINTENANCE' then 'MAINTENANCE'
    else null
  end;
$$;

comment on function public.job_title_for_primary_role(text) is
  'Login job title that matches a Staff Master primary role. Null for roles without one (SUPPORT_ROLE, DRIVER).';

revoke all on function public.job_title_for_primary_role(text) from public, anon, authenticated;

-- 2. Job titles that follow the Staff Master primary role.
create or replace function public.job_title_follows_primary_role(p_job_title_code text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select upper(trim(coalesce(p_job_title_code, ''))) in (
    'PRODUCTION_MANAGER', 'PRODUCTION_SUPERVISOR', 'TEAM_LEADER',
    'LABEL_OPERATIVE', 'GENERAL_OPERATIVE', 'CLEANER', 'MAINTENANCE'
  );
$$;

revoke all on function public.job_title_follows_primary_role(text) from public, anon, authenticated;

-- 3. Can the current user move a login from one job title to another?
create or replace function public.can_change_login_job_title(p_from_job_title_code text, p_to_job_title_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_my_rank integer;
  v_from_rank integer;
  v_to_rank integer;
begin
  if auth.uid() is null then
    return false;
  end if;
  if public.has_any_role(array['ADMIN']) then
    return true;
  end if;

  select jt.hierarchy_rank into v_my_rank
  from public.account_access_profiles ap
  join public.account_job_titles jt on jt.job_title_code = ap.job_title_code
  where ap.auth_user_id = auth.uid() and ap.account_type = 'USER';

  select jt.hierarchy_rank into v_from_rank from public.account_job_titles jt where jt.job_title_code = p_from_job_title_code;
  select jt.hierarchy_rank into v_to_rank from public.account_job_titles jt where jt.job_title_code = p_to_job_title_code;

  return v_my_rank is not null and v_to_rank is not null
    and v_my_rank < v_to_rank
    and (v_from_rank is null or v_my_rank < v_from_rank);
end;
$$;

revoke all on function public.can_change_login_job_title(text, text) from public, anon, authenticated;

-- 4. Staff Master save: same as before, plus the login job title.
create or replace function public.update_staff_master_with_current_roster_role(
  p_staff_id uuid,p_expected_row_version integer,p_display_name text,p_employee_code text,p_default_shift_code text,p_primary_role_code text,p_default_area_code text,p_default_station_code text,p_roster_eligible boolean,p_cover_role_codes text[],p_fire_training boolean,p_first_aid_training boolean,p_eod_capable boolean,p_joined_on date,p_notes text,p_import_review_required boolean default false,p_import_review_notes text default null,p_change_reason text default null,p_source_application text default 'STAFF_MASTER_UI',p_apply_current_roster_role boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_from_week_start date:=public.production_roster_week_start(current_date);
  v_staff public.staff_members%rowtype; v_old_role public.operational_roles%rowtype; v_new_role public.operational_roles%rowtype;
  v_result jsonb; v_base_updated integer:=0; v_snapshots_updated integer:=0; v_versions_updated integer:=0;
  v_login_job_title text; v_target_job_title text; v_target_job_title_name text; v_login_updated boolean:=false;
begin
  perform public.require_staff_master_manage_role();
  select sm.* into v_staff from public.staff_members sm where sm.staff_id=p_staff_id and sm.production_staff=true and sm.deleted_at is null for update;
  if not found then raise exception using errcode='P0002', message='Staff member not found.'; end if;
  select * into v_old_role from public.operational_roles where operational_role_id=v_staff.primary_operational_role_id;
  select * into v_new_role from public.operational_roles where role_code=upper(trim(coalesce(p_primary_role_code,''))) and active=true and allow_as_primary=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Primary role is invalid or inactive.'; end if;
  if coalesce(p_apply_current_roster_role,false) then perform public.require_production_roster_manage_role(); end if;

  -- Login job title that must follow the new primary role (checked before anything is saved).
  if v_staff.auth_user_id is not null and v_old_role.operational_role_id is distinct from v_new_role.operational_role_id then
    select ap.job_title_code into v_login_job_title
    from public.account_access_profiles ap
    where ap.auth_user_id=v_staff.auth_user_id and ap.account_type='USER';
    v_target_job_title:=public.job_title_for_primary_role(v_new_role.role_code);
    if v_login_job_title is not null and public.job_title_follows_primary_role(v_login_job_title)
       and v_target_job_title is not null and v_target_job_title is distinct from v_login_job_title then
      select jt.job_title_name into v_target_job_title_name from public.account_job_titles jt where jt.job_title_code=v_target_job_title;
      if not public.can_change_login_job_title(v_login_job_title,v_target_job_title) then
        raise exception using errcode='42501',
          message=format('You cannot make %s a %s. Only an Administrator or a job title above both %s and %s can change this primary role.',
            v_staff.display_name, coalesce(v_target_job_title_name,v_target_job_title),
            (select jt.job_title_name from public.account_job_titles jt where jt.job_title_code=v_login_job_title), coalesce(v_target_job_title_name,v_target_job_title));
      end if;
    else
      v_target_job_title:=null;
    end if;
  end if;

  v_result:=public.update_staff_master(p_staff_id,p_expected_row_version,p_display_name,p_employee_code,p_default_shift_code,p_primary_role_code,p_default_area_code,p_default_station_code,p_roster_eligible,p_cover_role_codes,p_fire_training,p_first_aid_training,p_eod_capable,p_joined_on,p_notes,p_import_review_required,p_import_review_notes,p_change_reason,p_source_application);

  if v_target_job_title is not null then
    v_login_updated:=public.apply_account_job_title_template(v_staff.auth_user_id,v_target_job_title,auth.uid());
    if v_login_updated then
      insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
      values(auth.uid(),public.current_staff_id(),'SYNC_LOGIN_JOB_TITLE_FROM_STAFF_MASTER','account_access_profiles',v_staff.auth_user_id::text,
        jsonb_build_object('staff_id',p_staff_id,'primary_role_code',v_old_role.role_code,'job_title_code',v_login_job_title),
        jsonb_build_object('staff_id',p_staff_id,'primary_role_code',v_new_role.role_code,'job_title_code',v_target_job_title),
        trim(p_change_reason),coalesce(nullif(trim(p_source_application),''),'STAFF_MASTER_UI'));
    end if;
  end if;

  if coalesce(p_apply_current_roster_role,false) then
    update public.production_roster_entries pre set operational_role_id=v_new_role.operational_role_id,operational_role_code_snapshot=v_new_role.role_code,operational_role_name_snapshot=v_new_role.role_name,updated_by=auth.uid()
    from public.production_roster_versions prv join public.roster_periods rp on rp.roster_period_id=prv.roster_period_id
    where pre.roster_version_id=prv.roster_version_id and rp.week_start>=v_from_week_start and prv.status='DRAFT' and pre.staff_id=p_staff_id and pre.assignment_type='BASE' and pre.operational_role_id is distinct from v_new_role.operational_role_id and pre.staff_primary_role_code_snapshot is distinct from v_new_role.role_code;
    get diagnostics v_base_updated=row_count;

    update public.production_roster_entries pre set staff_primary_role_code_snapshot=v_new_role.role_code,staff_primary_role_name_snapshot=v_new_role.role_name,updated_by=auth.uid()
    from public.production_roster_versions prv join public.roster_periods rp on rp.roster_period_id=prv.roster_period_id
    where pre.roster_version_id=prv.roster_version_id and rp.week_start>=v_from_week_start and prv.status='DRAFT' and pre.staff_id=p_staff_id and pre.staff_primary_role_code_snapshot is distinct from v_new_role.role_code;
    get diagnostics v_snapshots_updated=row_count;

    update public.production_roster_versions prv set row_version=prv.row_version+1,saved_at=now(),saved_by=auth.uid(),updated_by=auth.uid()
    from public.roster_periods rp
    where rp.roster_period_id=prv.roster_period_id and rp.week_start>=v_from_week_start and prv.status='DRAFT' and exists(select 1 from public.production_roster_entries pre where pre.roster_version_id=prv.roster_version_id and pre.staff_id=p_staff_id and pre.staff_primary_role_code_snapshot=v_new_role.role_code);
    get diagnostics v_versions_updated=row_count;

    insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
    values(auth.uid(),public.current_staff_id(),'APPLY_STAFF_PRIMARY_ROLE_TO_CURRENT_ROSTER','production_roster_entries',p_staff_id::text,jsonb_build_object('primary_role_code',v_old_role.role_code),jsonb_build_object('primary_role_code',v_new_role.role_code,'from_week_start',v_from_week_start,'base_assignments_updated',v_base_updated,'staff_snapshots_updated',v_snapshots_updated,'draft_versions_updated',v_versions_updated),trim(p_change_reason),coalesce(nullif(trim(p_source_application),''),'STAFF_MASTER_UI'));
  end if;

  return v_result||jsonb_build_object('current_roster_role_applied',coalesce(p_apply_current_roster_role,false),'current_roster_base_assignments_updated',v_base_updated,'current_roster_staff_snapshots_updated',v_snapshots_updated,'current_roster_draft_versions_updated',v_versions_updated,
    'login_job_title_updated',v_login_updated,'login_job_title_code',case when v_login_updated then v_target_job_title end,'login_job_title_name',case when v_login_updated then v_target_job_title_name end);
end;
$$;

revoke all on function public.update_staff_master_with_current_roster_role(uuid,integer,text,text,text,text,text,text,boolean,text[],boolean,boolean,boolean,date,text,boolean,text,text,text,boolean) from public, anon;
grant execute on function public.update_staff_master_with_current_roster_role(uuid,integer,text,text,text,text,text,text,boolean,text[],boolean,boolean,boolean,date,text,boolean,text,text,text,boolean) to authenticated;

-- 5. Repair logins that already disagree with Staff Master.
do $$
declare
  v_row record;
begin
  for v_row in
    select sm.staff_id, sm.employee_code, sm.auth_user_id, r.role_code, ap.job_title_code as old_job_title,
      public.job_title_for_primary_role(r.role_code) as new_job_title
    from public.staff_members sm
    join public.operational_roles r on r.operational_role_id = sm.primary_operational_role_id
    join public.account_access_profiles ap on ap.auth_user_id = sm.auth_user_id and ap.account_type = 'USER'
    where sm.deleted_at is null
      and sm.production_staff
      and public.job_title_follows_primary_role(ap.job_title_code)
      and public.job_title_for_primary_role(r.role_code) is not null
      and public.job_title_for_primary_role(r.role_code) is distinct from ap.job_title_code
  loop
    perform public.apply_account_job_title_template(v_row.auth_user_id, v_row.new_job_title, null);
    insert into public.audit_log(actor_auth_user_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
    values (null, 'SYNC_LOGIN_JOB_TITLE_FROM_STAFF_MASTER', 'account_access_profiles', v_row.auth_user_id::text,
      jsonb_build_object('staff_id', v_row.staff_id, 'employee_code', v_row.employee_code, 'primary_role_code', v_row.role_code, 'job_title_code', v_row.old_job_title),
      jsonb_build_object('staff_id', v_row.staff_id, 'employee_code', v_row.employee_code, 'primary_role_code', v_row.role_code, 'job_title_code', v_row.new_job_title),
      'Owner report 2026-11-01: login job title did not follow the Staff Master primary role',
      'migration 202611030002');
  end loop;
end;
$$;

commit;
