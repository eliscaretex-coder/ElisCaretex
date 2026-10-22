-- Allow enabled accounts that are not linked to a staff record (for example an ADMIN
-- account managed through account_access_profiles / account_roles) through the identity
-- guards of Distribution, Finish, MOP, Customer Schedules, operational reports, ABS batch
-- entry and the Trolley Type Master.
--
-- These guards required public.current_staff_id() before checking roles, so an ADMIN
-- account without a staff record got "An active authenticated staff account is required."
-- They now require public.current_account_is_enabled(), which:
--   - accepts active production terminals;
--   - for accounts linked to a staff record, still requires that staff record to be active
--     and not deactivated;
--   - accepts accounts with no staff link, whose permission then comes only from
--     account_roles through public.has_any_role().
-- The role checks are unchanged. Actor columns that receive current_staff_id()
-- (reviewed_by_staff_id, actor_staff_id, ...) are nullable and auth.uid() is still recorded.

create or replace function public.require_distribution_read_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;
  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']) then
    raise exception using errcode = '42501', message = 'Your active role does not allow access to Distribution.';
  end if;
end;
$$;

create or replace function public.require_finish_production_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'An authenticated Finish account is required.';
  end if;

  if not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active Finish account or registered Finish computer is required.';
  end if;

  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Your role cannot use Finish Production.';
  end if;
end;
$$;

create or replace function public.begin_mop_operational_scope()
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow access to MOP Production.';
  end if;

  if not public.current_account_is_enabled() then
    raise exception using
      errcode='42501',
      message='MOP Production requires an active account or a registered Sorting terminal.';
  end if;

  perform set_config('eliscaretex.mop_operational_scope','on',true);
end;
$$;

create or replace function public.require_customer_schedule_edit_role()
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using
      errcode = '42501',
      message = 'An active authenticated account is required.';
  end if;

  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to manage Customer Schedules.';
  end if;
end;
$$;

create or replace function public.require_operational_report_submit_access(p_source_area_code text, p_product_code text)
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare
  v_area text := upper(trim(coalesce(p_source_area_code, '')));
  v_product text := upper(trim(coalesce(p_product_code, '')));
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'An authenticated account is required.';
  end if;

  if not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active account or registered production computer is required.';
  end if;

  if v_area = 'MOP' and v_product = 'MOP' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR','SORTING_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report MOP operational schedule data.';
    end if;
    return;
  end if;

  if v_area = 'FINISH' and v_product = 'CLOTHES' then
    if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report Finish operational schedule data.';
    end if;
    return;
  end if;

  raise exception using errcode = '42501', message = 'The requested operational report area/product scope is not allowed.';
end;
$$;

create or replace function public.require_production_flow_abs_batch_write_access(p_production_flow_item_id uuid)
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare
  v_product_code text;
  v_has_mop_production boolean:=false;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using
      errcode='42501',
      message='An active authenticated account is required for ABS production batch entry.';
  end if;

  select pfi.product_code into v_product_code
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;

  if not found then
    raise exception using errcode='P0002',message='Production Flow Item was not found.';
  end if;

  if public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']) then
    return;
  end if;

  if public.has_any_role(array['FINISH_OPERATOR']) and v_product_code='CLOTHES' then
    return;
  end if;

  if public.has_any_role(array['MOP_OPERATOR']) and v_product_code='MOP' then
    return;
  end if;

  if public.has_any_role(array['SORTING_OPERATOR']) and v_product_code='MOP' then
    select exists(
      select 1 from public.sorting_mop_production_batches mb
      where mb.production_flow_item_id=p_production_flow_item_id
        and mb.status='RECORDED'
    ) into v_has_mop_production;
    if v_has_mop_production then return; end if;
  end if;

  raise exception using
    errcode='42501',
    message='Your active role does not allow ABS production batch entry for this Production Flow item.';
end;
$$;

create or replace function public.require_production_flow_batch_write_role()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null
     or not public.current_account_is_enabled()
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow ABS production batch entry.';
  end if;
end;
$$;

create or replace function public.require_trolley_type_master_write_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null
     or not public.current_account_is_enabled()
     or not public.has_any_role(array['ADMIN','MANAGER']) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow Trolley Type Master changes.';
  end if;
end;
$$;

create or replace function public.review_operational_schedule_report(p_operational_report_id uuid, p_action text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare
  v_action text := upper(trim(coalesce(p_action,'')));
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_report public.operational_data_reports%rowtype;
  v_staff_id uuid;
  v_resolution_version uuid;
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode='42501', message='An active authenticated account is required.';
  end if;
  if not public.can_handle_trolley_plan_checks() then
    raise exception using errcode='42501', message='Your account cannot resolve trolley plan checks.';
  end if;
  if p_operational_report_id is null then
    raise exception using errcode='22023', message='Operational report is required.';
  end if;
  if v_action not in ('RESOLVED','REJECTED') then
    raise exception using errcode='22023', message='Review action must be RESOLVED or REJECTED.';
  end if;
  if v_notes is null then
    raise exception using errcode='22023', message='Review notes are required.';
  end if;
  if length(v_notes)>1000 then
    raise exception using errcode='22023', message='Review notes must be 1000 characters or fewer.';
  end if;

  select * into v_report
  from public.operational_data_reports
  where operational_report_id=p_operational_report_id
  for update;
  if not found then
    raise exception using errcode='P0002', message='Operational report was not found.';
  end if;
  if v_report.status<>'PENDING' then
    raise exception using errcode='22023', message='This operational report has already been reviewed.';
  end if;

  if v_action='RESOLVED' then
    select v.schedule_version_id into v_resolution_version
    from public.customer_schedule_versions v
    where v.customer_id=v_report.customer_id
      and v.status='PUBLISHED'
      and v_report.business_date>=v.effective_from
      and (v.effective_until is null or v_report.business_date<=v.effective_until)
    order by v.version_number desc
    limit 1;
  end if;

  v_staff_id := public.current_staff_id();
  update public.operational_data_reports
  set status=v_action,
      reviewed_by_staff_id=v_staff_id,
      reviewed_by_auth_user_id=auth.uid(),
      reviewed_at=now(),
      review_notes=v_notes,
      resolution_schedule_version_id=v_resolution_version,
      updated_at=now(),
      row_version=row_version+1
  where operational_report_id=p_operational_report_id
  returning * into v_report;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),v_staff_id,'OPERATIONAL_TROLLEY_REQUIREMENT_'||v_action,'operational_data_reports',
    v_report.operational_report_id::text,to_jsonb(v_report),v_notes,'CUSTOMER_SCHEDULE_UI'
  );

  return jsonb_build_object(
    'status','success',
    'operational_report_id',v_report.operational_report_id,
    'report_status',v_report.status,
    'message',case when v_action='RESOLVED'
      then 'Trolley check resolved. Published schedule history remains versioned.'
      else 'Trolley check closed with no change; the reason is preserved.' end
  );
end;
$$;
