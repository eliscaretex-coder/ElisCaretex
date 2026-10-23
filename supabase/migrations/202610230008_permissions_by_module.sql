-- =====================================================================
-- ElisCaretex V2
-- Module permissions decide access for personal accounts
--
-- Owner decision 2026-10-23: for every module, what is ticked in Accounts &
-- Access (account_permission_grants) decides what a personal (USER) account
-- can do. Legacy roles only decide access for production terminals and for
-- accounts without an access profile.
--
-- Before: Distribution, Sorting, Finish, Customers and Trolleys checked
-- roles only; Customer Service and Driver Guides checked grants only;
-- Production Roster and Staff Master switched to grants when an account had
-- any grant at all. Consequences: a Logistics Manager with
-- DISTRIBUTION:MANAGE could not maintain drivers/fleet/routes, a manager who
-- received a Customer Service grant lost the Production Roster, and the
-- DRIVER job title carried the DISTRIBUTION_OPERATOR role, i.e. it could
-- edit customers and publish the Distribution Roster.
--
-- 1. Helpers: account_uses_module_permissions, account_module_allowed,
--    legacy_role_allowed, legacy_role_modules, trolley_action_for_roles.
-- 2. Job-title templates completed so every title keeps the access of its
--    area (owner-approved matrix, revisao-logica-banco/permissoes-por-modulo.md);
--    existing accounts receive the new template rows (only additions).
-- 3. DRIVER no longer carries DISTRIBUTION_OPERATOR.
-- 4. Every role check in the module guards and capability flags uses
--    account_module_allowed(modules, action, legacy roles). Bodies are the
--    live definitions with only those calls changed.
-- 5. Direct-read RLS policies on customers, staff_members and staff_roles
--    follow the same rule.
--
-- Action mapping: VIEW = read; EDIT = operate / plan / create / update;
-- APPROVE = supervisor-level production overrides; MANAGE = master data,
-- deactivation, type catalogues.
-- =====================================================================

begin;

-- 1. Helpers ------------------------------------------------------------

create or replace function public.account_uses_module_permissions()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1 from public.account_access_profiles ap
    where ap.auth_user_id = auth.uid() and ap.account_type = 'USER'
  );
$$;

create or replace function public.account_module_allowed(p_modules text[], p_action text, p_legacy_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select case
    when auth.uid() is null then false
    when public.account_uses_module_permissions() then exists (
      select 1 from unnest(coalesce(p_modules, array[]::text[])) m
      where public.has_account_permission(m, p_action, null)
    )
    else public.has_any_role(coalesce(p_legacy_roles, array[]::text[]))
  end;
$$;

-- Role-only shortcuts (for example the Customer Service MANAGER bypass) no
-- longer apply to personal accounts.
create or replace function public.legacy_role_allowed(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select not public.account_uses_module_permissions() and public.has_any_role(p_roles);
$$;

-- Modules that correspond to the operational roles a caller lists, used by
-- the shared customer-read and trolley guards.
create or replace function public.legacy_role_modules(p_roles text[])
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct m), array[]::text[])
  from unnest(coalesce(p_roles, array[]::text[])) r
  cross join lateral unnest(case upper(r)
    when 'SORTING_OPERATOR' then array['SORTING']
    when 'FINISH_OPERATOR' then array['FINISH']
    when 'MOP_OPERATOR' then array['MOP']
    when 'DISTRIBUTION_OPERATOR' then array['DISTRIBUTION']
    when 'SUPERVISOR' then array['SORTING','FINISH','MOP']
    when 'PLANNER' then array['CUSTOMERS']
    when 'ROSTER_MANAGER' then array['PRODUCTION_ROSTER']
    else array[]::text[] end) m;
$$;

create or replace function public.trolley_action_for_roles(p_roles text[])
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when 'AUDITOR' = any(p_roles) then 'VIEW'
    when p_roles <@ array['ADMIN','MANAGER'] then 'MANAGE'
    else 'EDIT'
  end;
$$;

revoke all on function public.account_uses_module_permissions() from public, anon;
revoke all on function public.account_module_allowed(text[], text, text[]) from public, anon;
revoke all on function public.legacy_role_allowed(text[]) from public, anon;
revoke all on function public.legacy_role_modules(text[]) from public, anon;
revoke all on function public.trolley_action_for_roles(text[]) from public, anon;
-- RLS policies evaluate these as the signed-in user.
grant execute on function public.account_uses_module_permissions() to authenticated;
grant execute on function public.account_module_allowed(text[], text, text[]) to authenticated;
grant execute on function public.legacy_role_modules(text[]) to authenticated;

-- 2. Job-title templates ------------------------------------------------

with v(job_title_code, module_code, access_scope, lvl) as (values
  ('GENERAL_MANAGER','CUSTOMERS','ALL','M'),
  ('GENERAL_MANAGER','SORTING','ALL','M'),
  ('GENERAL_MANAGER','FINISH','ALL','M'),
  ('GENERAL_MANAGER','MOP','ALL','M'),
  ('GENERAL_MANAGER','TROLLEYS','ALL','M'),
  ('GENERAL_MANAGER','PRODUCTION_TRACKER','ALL','V'),
  ('GENERAL_MANAGER','DISTRIBUTION','ALL','M'),
  ('PRODUCTION_MANAGER','SORTING','PRODUCTION','M'),
  ('PRODUCTION_MANAGER','FINISH','PRODUCTION','M'),
  ('PRODUCTION_MANAGER','MOP','PRODUCTION','M'),
  ('PRODUCTION_MANAGER','PRODUCTION_TRACKER','PRODUCTION','V'),
  ('PRODUCTION_MANAGER','TROLLEYS','PRODUCTION','E'),
  ('PRODUCTION_MANAGER','CUSTOMERS','PRODUCTION','V'),
  ('PRODUCTION_SUPERVISOR','CUSTOMERS','PRODUCTION','V'),
  ('PRODUCTION_SUPERVISOR','PRODUCTION_TRACKER','PRODUCTION','V'),
  ('LOGISTICS_MANAGER','CUSTOMERS','DISTRIBUTION','E'),
  ('AUDITOR','CUSTOMERS','ALL','V'),
  ('AUDITOR','SORTING','ALL','V'),
  ('AUDITOR','FINISH','ALL','V'),
  ('AUDITOR','MOP','ALL','V'),
  ('AUDITOR','TROLLEYS','ALL','V'),
  ('AUDITOR','PRODUCTION_TRACKER','ALL','V')
), rows as (
  select job_title_code, module_code, access_scope,
    true as can_view,
    lvl in ('E','M') as can_create,
    lvl in ('E','M') as can_edit,
    lvl = 'M' as can_approve,
    lvl = 'M' as can_manage
  from v
), tpl as (
  insert into public.job_title_permission_templates(job_title_code, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
  select * from rows
  on conflict (job_title_code, module_code) do update set
    access_scope = excluded.access_scope,
    can_view = public.job_title_permission_templates.can_view or excluded.can_view,
    can_create = public.job_title_permission_templates.can_create or excluded.can_create,
    can_edit = public.job_title_permission_templates.can_edit or excluded.can_edit,
    can_approve = public.job_title_permission_templates.can_approve or excluded.can_approve,
    can_manage = public.job_title_permission_templates.can_manage or excluded.can_manage
  returning 1
)
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage, granted_by_auth_user_id)
select ap.auth_user_id, r.module_code, r.access_scope, r.can_view, r.can_create, r.can_edit, r.can_approve, r.can_manage, null
from rows r
join public.account_access_profiles ap on ap.job_title_code = r.job_title_code and ap.account_type = 'USER'
on conflict (auth_user_id, module_code) do update set
  can_view = public.account_permission_grants.can_view or excluded.can_view,
  can_create = public.account_permission_grants.can_create or excluded.can_create,
  can_edit = public.account_permission_grants.can_edit or excluded.can_edit,
  can_approve = public.account_permission_grants.can_approve or excluded.can_approve,
  can_manage = public.account_permission_grants.can_manage or excluded.can_manage,
  updated_at = now();

-- 3. DRIVER keeps My Driver Roster only ---------------------------------

delete from public.job_title_legacy_roles
where job_title_code = 'DRIVER' and role_code = 'DISTRIBUTION_OPERATOR';

update public.account_roles ar set active = false
from public.account_access_profiles ap, public.roles r
where ap.auth_user_id = ar.auth_user_id
  and ap.job_title_code = 'DRIVER'
  and r.role_id = ar.role_id
  and r.role_code = 'DISTRIBUTION_OPERATOR'
  and ar.active;

-- 4. Guards and capability flags ----------------------------------------

-- begin_mop_operational_scope()
CREATE OR REPLACE FUNCTION public.begin_mop_operational_scope()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null
     or not public.account_module_allowed(array['MOP'],'EDIT',array[
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
$function$;

-- can_handle_trolley_plan_checks()
CREATE OR REPLACE FUNCTION public.can_handle_trolley_plan_checks()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select auth.uid() is not null and (
    public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR'])
    or public.has_account_permission('DISTRIBUTION','EDIT',null)
    or (public.current_account_is_enabled() and exists(
      select 1
      from public.staff_members sm
      join public.operational_roles o on o.operational_role_id = sm.primary_operational_role_id
      where sm.auth_user_id = auth.uid()
        and sm.active and sm.deleted_at is null
        and o.role_code = 'PRODUCTION_MANAGER'
    ))
  );
$function$;

-- cancel_customer_schedule_version(p_schedule_version_id uuid, p_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.cancel_customer_schedule_version(p_schedule_version_id uuid, p_reason text, p_source_application text DEFAULT 'CUSTOMER_SCHEDULE_MANAGEMENT'::text)
 RETURNS customer_schedule_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_old public.customer_schedule_versions%rowtype;
  v_version public.customer_schedule_versions%rowtype;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for schedule cancellation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A cancellation reason is required.';
  end if;

  select *
  into v_old
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception 'Schedule version not found.';
  end if;

  if v_old.status = 'PUBLISHED' and v_old.effective_from <= public.current_business_date() then
    raise exception 'A current or historical published version cannot be cancelled. Publish a replacement revision instead.';
  end if;

  if v_old.status not in ('DRAFT', 'PUBLISHED') then
    raise exception 'Only a draft or future published version can be cancelled.';
  end if;

  update public.customer_schedule_versions
  set
    status = 'CANCELLED',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, trim(p_reason)),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id
  returning * into v_version;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CANCEL_CUSTOMER_SCHEDULE_VERSION',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    to_jsonb(v_old),
    to_jsonb(v_version),
    trim(p_reason),
    p_source_application
  );

  return v_version;
end;
$function$;

-- create_customer(p_customer_code text, p_customer_name text, p_eircode text, p_distribution_estimated_kg numeric, p_distribution_stop_count integer, p_notes text, p_operational_alert text, p_product_codes text[], p_change_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.create_customer(p_customer_code text, p_customer_name text, p_eircode text DEFAULT NULL::text, p_distribution_estimated_kg numeric DEFAULT NULL::numeric, p_distribution_stop_count integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_operational_alert text DEFAULT NULL::text, p_product_codes text[] DEFAULT ARRAY[]::text[], p_change_reason text DEFAULT NULL::text, p_source_application text DEFAULT 'CUSTOMER_MANAGEMENT'::text)
 RETURNS customers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for customer creation.';
  end if;

  if nullif(trim(p_customer_code), '') is null then
    raise exception 'Customer code is required.';
  end if;

  if nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer name is required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one customer product service is required for an active customer.';
  end if;

  insert into public.customers (
    customer_code,
    customer_name,
    eircode,
    distribution_estimated_kg,
    distribution_stop_count,
    notes,
    operational_alert,
    active,
    created_by,
    updated_by
  )
  values (
    upper(trim(p_customer_code)),
    trim(p_customer_name),
    nullif(trim(p_eircode), ''),
    p_distribution_estimated_kg,
    p_distribution_stop_count,
    nullif(trim(p_notes), ''),
    nullif(trim(p_operational_alert), ''),
    true,
    auth.uid(),
    auth.uid()
  )
  returning * into v_customer;

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = v_customer.customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        v_customer.customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
  end loop;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CREATE_CUSTOMER',
    'customers',
    v_customer.customer_id::text,
    to_jsonb(v_customer),
    nullif(trim(p_change_reason), ''),
    p_source_application
  );

  return v_customer;
end;
$function$;

-- create_customer_master(p_customer_name text, p_eircode text, p_distribution_estimated_kg numeric, p_distribution_stop_count integer, p_notes text, p_operational_alert text, p_product_codes text[], p_change_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.create_customer_master(p_customer_name text, p_eircode text DEFAULT NULL::text, p_distribution_estimated_kg numeric DEFAULT NULL::numeric, p_distribution_stop_count integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_operational_alert text DEFAULT NULL::text, p_product_codes text[] DEFAULT ARRAY[]::text[], p_change_reason text DEFAULT NULL::text, p_source_application text DEFAULT 'CUSTOMER_MASTER_UI'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_customer public.customers%rowtype;
  v_customer_code text;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to create customers.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A creation reason is required.';
  end if;

  v_customer_code := public.generate_customer_code(p_customer_name);

  select *
  into v_customer
  from public.create_customer(
    v_customer_code,
    p_customer_name,
    p_eircode,
    p_distribution_estimated_kg,
    p_distribution_stop_count,
    p_notes,
    p_operational_alert,
    p_product_codes,
    p_change_reason,
    p_source_application
  );

  return jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_name', v_customer.customer_name,
    'active', v_customer.active,
    'row_version', v_customer.row_version
  );
end;
$function$;

-- create_customer_schedule_draft(p_customer_id uuid, p_effective_from date, p_based_on_version_id uuid, p_change_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.create_customer_schedule_draft(p_customer_id uuid, p_effective_from date, p_based_on_version_id uuid DEFAULT NULL::uuid, p_change_reason text DEFAULT NULL::text, p_source_application text DEFAULT 'CUSTOMER_SCHEDULE_MANAGEMENT'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_base_version_id uuid;
  v_new_version_id uuid;
  v_new_version_number integer;
  v_new_day_id uuid;
  v_new_product_id uuid;
  v_new_requirement_id uuid;
  v_day_map jsonb := '{}'::jsonb;
  v_product_map jsonb := '{}'::jsonb;
  v_old_day record;
  v_old_product record;
  v_old_requirement record;
  v_old_mapping record;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for schedule draft creation.';
  end if;

  if p_effective_from is null then
    raise exception 'The proposed effective date is required.';
  end if;

  if not exists (
    select 1
    from public.customers
    where customer_id = p_customer_id
      and active = true
      and deleted_at is null
  ) then
    raise exception 'Customer is not active or does not exist.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'DRAFT'
  ) then
    raise exception 'This customer already has an open schedule draft.';
  end if;

  v_base_version_id := p_based_on_version_id;

  if v_base_version_id is not null then
    if not exists (
      select 1
      from public.customer_schedule_versions
      where schedule_version_id = v_base_version_id
        and customer_id = p_customer_id
        and status in ('PUBLISHED', 'SUPERSEDED', 'CANCELLED')
    ) then
      raise exception 'The selected base schedule does not belong to this customer or cannot be copied.';
    end if;
  else
    select schedule_version_id
    into v_base_version_id
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'PUBLISHED'
      and effective_from <= p_effective_from
    order by effective_from desc, version_number desc
    limit 1;
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_new_version_number
  from public.customer_schedule_versions
  where customer_id = p_customer_id;

  insert into public.customer_schedule_versions (
    customer_id,
    version_number,
    status,
    effective_from,
    based_on_version_id,
    source_code,
    change_reason,
    created_by,
    updated_by
  )
  values (
    p_customer_id,
    v_new_version_number,
    'DRAFT',
    p_effective_from,
    v_base_version_id,
    'MANUAL',
    nullif(trim(p_change_reason), ''),
    auth.uid(),
    auth.uid()
  )
  returning schedule_version_id into v_new_version_id;

  if v_base_version_id is not null then
    for v_old_day in
      select *
      from public.customer_schedule_days
      where schedule_version_id = v_base_version_id
        and active = true
      order by production_weekday
    loop
      insert into public.customer_schedule_days (
        schedule_version_id,
        production_weekday,
        delivery_weekday,
        default_route_id,
        delivery_window_start,
        delivery_window_end,
        delivery_order,
        day_alert,
        distribution_instructions,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_new_version_id,
        v_old_day.production_weekday,
        v_old_day.delivery_weekday,
        v_old_day.default_route_id,
        v_old_day.delivery_window_start,
        v_old_day.delivery_window_end,
        v_old_day.delivery_order,
        v_old_day.day_alert,
        v_old_day.distribution_instructions,
        v_old_day.active,
        v_old_day.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_day_id into v_new_day_id;

      v_day_map := jsonb_set(
        v_day_map,
        array[v_old_day.schedule_day_id::text],
        to_jsonb(v_new_day_id::text),
        true
      );

      for v_old_product in
        select *
        from public.customer_schedule_products
        where schedule_day_id = v_old_day.schedule_day_id
          and active = true
        order by production_order nulls last, created_at
      loop
        insert into public.customer_schedule_products (
          schedule_day_id,
          product_type_id,
          production_order,
          expected_kg,
          expected_units,
          production_instructions,
          active,
          metadata,
          created_by,
          updated_by
        )
        values (
          v_new_day_id,
          v_old_product.product_type_id,
          v_old_product.production_order,
          v_old_product.expected_kg,
          v_old_product.expected_units,
          v_old_product.production_instructions,
          v_old_product.active,
          v_old_product.metadata,
          auth.uid(),
          auth.uid()
        )
        returning schedule_product_id into v_new_product_id;

        v_product_map := jsonb_set(
          v_product_map,
          array[v_old_product.schedule_product_id::text],
          to_jsonb(v_new_product_id::text),
          true
        );

        insert into public.customer_schedule_product_variants (
          schedule_product_id,
          product_variant_id,
          created_by
        )
        select
          v_new_product_id,
          old_variant.product_variant_id,
          auth.uid()
        from public.customer_schedule_product_variants old_variant
        where old_variant.schedule_product_id = v_old_product.schedule_product_id;
      end loop;
    end loop;

    for v_old_requirement in
      select *
      from public.customer_schedule_trolley_requirements
      where schedule_day_id in (
        select schedule_day_id
        from public.customer_schedule_days
        where schedule_version_id = v_base_version_id
      )
        and active = true
      order by created_at
    loop
      insert into public.customer_schedule_trolley_requirements (
        schedule_day_id,
        trolley_type_id,
        owner_schedule_product_id,
        quantity,
        empty_trolley,
        notes,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        (v_day_map ->> v_old_requirement.schedule_day_id::text)::uuid,
        v_old_requirement.trolley_type_id,
        (v_product_map ->> v_old_requirement.owner_schedule_product_id::text)::uuid,
        v_old_requirement.quantity,
        v_old_requirement.empty_trolley,
        v_old_requirement.notes,
        v_old_requirement.active,
        v_old_requirement.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_trolley_requirement_id into v_new_requirement_id;

      for v_old_mapping in
        select schedule_product_id
        from public.customer_schedule_trolley_requirement_products
        where schedule_trolley_requirement_id =
          v_old_requirement.schedule_trolley_requirement_id
      loop
        insert into public.customer_schedule_trolley_requirement_products (
          schedule_trolley_requirement_id,
          schedule_product_id,
          created_by
        )
        values (
          v_new_requirement_id,
          (v_product_map ->> v_old_mapping.schedule_product_id::text)::uuid,
          auth.uid()
        );
      end loop;
    end loop;
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CREATE_CUSTOMER_SCHEDULE_DRAFT',
    'customer_schedule_versions',
    v_new_version_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'version_number', v_new_version_number,
      'effective_from', p_effective_from,
      'based_on_version_id', v_base_version_id
    ),
    nullif(trim(p_change_reason), ''),
    p_source_application
  );

  return v_new_version_id;
end;
$function$;

-- create_sorting_mop_type_master(p_variant_code text, p_display_name text, p_category text, p_unit_weight_grams numeric, p_notes text, p_image_url text, p_sort_order integer)
CREATE OR REPLACE FUNCTION public.create_sorting_mop_type_master(p_variant_code text, p_display_name text, p_category text DEFAULT NULL::text, p_unit_weight_grams numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_image_url text DEFAULT NULL::text, p_sort_order integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_actor_staff_id uuid;
  v_product_type_id uuid;
  v_variant public.product_variants%rowtype;
  v_code text;
  v_category text;
  v_notes text;
  v_image_url text;
  v_metadata jsonb := jsonb_build_object('source','MOP_TYPE_MASTER');
  v_sort_order integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication is required.';
  end if;

  v_actor_staff_id := public.current_staff_id();
  if not public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']) then
    raise exception using errcode = '42501', message = 'Only ADMIN or MANAGER may create MOP Types.';
  end if;

  if nullif(trim(coalesce(p_display_name,'')), '') is null then
    raise exception using errcode = '22023', message = 'MOP type name is required.';
  end if;
  if length(trim(p_display_name)) > 160 then
    raise exception using errcode = '22023', message = 'MOP type name is too long.';
  end if;

  v_code := upper(regexp_replace(trim(coalesce(p_variant_code,'')), '[^A-Za-z0-9]+', '_', 'g'));
  v_code := regexp_replace(regexp_replace(v_code, '^_+', ''), '_+$', '');
  if v_code !~ '^[A-Z0-9][A-Z0-9_]{1,79}$' then
    raise exception using errcode = '22023', message = 'Variant code must use only A-Z, 0-9 and underscore, with at least 2 characters.';
  end if;

  v_category := nullif(trim(coalesce(p_category,'')), '');
  if length(coalesce(v_category,'')) > 120 then
    raise exception using errcode = '22023', message = 'MOP type category is too long.';
  end if;

  if p_unit_weight_grams is not null and p_unit_weight_grams <= 0 then
    raise exception using errcode = '22023', message = 'Unit weight must be greater than zero when provided.';
  end if;

  v_notes := nullif(trim(coalesce(p_notes,'')), '');
  if length(coalesce(v_notes,'')) > 1000 then
    raise exception using errcode = '22023', message = 'MOP type notes are too long.';
  end if;

  v_image_url := nullif(trim(coalesce(p_image_url,'')), '');
  if length(coalesce(v_image_url,'')) > 2000 then
    raise exception using errcode = '22023', message = 'MOP type image URL is too long.';
  end if;
  if v_image_url is not null
     and position('/storage/v1/object/public/mop-type-photos/' in v_image_url) = 0 then
    raise exception using errcode = '22023', message = 'MOP type image must come from the mop-type-photos Storage bucket.';
  end if;

  if p_sort_order is not null and (p_sort_order < 0 or p_sort_order > 100000) then
    raise exception using errcode = '22023', message = 'Display order must be between 0 and 100000.';
  end if;

  select pt.product_type_id
  into v_product_type_id
  from public.product_types pt
  where pt.product_code = 'MOP'
    and pt.active = true
    and pt.deleted_at is null;

  if v_product_type_id is null then
    raise exception using errcode = 'P0002', message = 'Active MOP product type master was not found.';
  end if;

  if exists(
    select 1
    from public.product_variants pv
    where pv.product_type_id = v_product_type_id
      and pv.variant_code = v_code
  ) then
    raise exception using errcode = '23505', message = format('MOP variant code %s already exists.', v_code);
  end if;

  if p_unit_weight_grams is not null then
    v_metadata := jsonb_set(v_metadata, '{unit_weight_grams}', to_jsonb(round(p_unit_weight_grams,3)), true);
    v_metadata := jsonb_set(v_metadata, '{unit_weight_source}', to_jsonb('MOP_TYPE_MASTER_MANUAL'::text), true);
    v_metadata := v_metadata - 'unit_weight_review_required';
  end if;
  if v_category is not null then
    v_metadata := jsonb_set(v_metadata, '{category}', to_jsonb(v_category), true);
  end if;
  if v_notes is not null then
    v_metadata := jsonb_set(v_metadata, '{notes}', to_jsonb(v_notes), true);
  end if;
  if v_image_url is not null then
    v_metadata := jsonb_set(v_metadata, '{image_url}', to_jsonb(v_image_url), true);
  end if;

  if p_sort_order is null then
    select coalesce(max(pv.sort_order),0) + 10
    into v_sort_order
    from public.product_variants pv
    where pv.product_type_id = v_product_type_id
      and pv.deleted_at is null;
  else
    v_sort_order := p_sort_order;
  end if;

  insert into public.product_variants(
    product_type_id, variant_code, display_name, active, sort_order, metadata,
    created_by, updated_by
  ) values (
    v_product_type_id, v_code, trim(p_display_name), true, v_sort_order, v_metadata,
    auth.uid(), auth.uid()
  )
  returning * into v_variant;

  insert into public.audit_log(
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'MOP_TYPE_MASTER_CREATED', 'product_variants',
    v_variant.product_variant_id::text, null, to_jsonb(v_variant),
    'New MOP type created from Sorting MOP Types Management', 'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'product_variant_id', v_variant.product_variant_id,
    'variant_code', v_variant.variant_code,
    'display_name', v_variant.display_name,
    'active', v_variant.active,
    'sort_order', v_variant.sort_order,
    'category', nullif(coalesce(v_variant.metadata->>'category',''),''),
    'unit_weight_grams', case
      when coalesce(v_variant.metadata->>'unit_weight_grams','') ~ '^[0-9]+([.][0-9]+)?$'
        then (v_variant.metadata->>'unit_weight_grams')::numeric
      else null end,
    'image_url', nullif(coalesce(v_variant.metadata->>'image_url',''),''),
    'notes', nullif(coalesce(v_variant.metadata->>'notes',''),''),
    'message', 'MOP type created.'
  );
end;
$function$;

-- customer_service_access_scope()
CREATE OR REPLACE FUNCTION public.customer_service_access_scope()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select case
    when auth.uid() is null or not public.current_account_is_enabled() then null
    when public.legacy_role_allowed(array['ADMIN','MANAGER']) then 'ALL'
    when public.has_account_permission('CUSTOMER_SERVICE','VIEW','ALL') then 'ALL'
    when public.has_account_permission('CUSTOMER_SERVICE','VIEW',null) then 'OWN'
    else null end;
$function$;

-- customer_service_can(p_action text)
CREATE OR REPLACE FUNCTION public.customer_service_can(p_action text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select public.customer_service_access_scope() is not null and (
    public.legacy_role_allowed(array['ADMIN','MANAGER'])
    or public.has_account_permission('CUSTOMER_SERVICE',p_action,null));
$function$;

-- deactivate_customer(p_customer_id uuid, p_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.deactivate_customer(p_customer_id uuid, p_reason text, p_source_application text DEFAULT 'CUSTOMER_MANAGEMENT'::text)
 RETURNS customers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'MANAGE',array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for customer deactivation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A deactivation reason is required.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if not v_old.active then
    return v_old;
  end if;

  update public.customers
  set
    active = false,
    deactivated_at = now(),
    deactivated_by = auth.uid(),
    deactivation_reason = trim(p_reason),
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  update public.customer_product_services
  set
    active = false,
    effective_until = public.current_business_date(),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and active = true
    and deleted_at is null;

  update public.customer_schedule_versions
  set
    status = 'CANCELLED',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, 'Customer deactivated: ' || trim(p_reason)),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and status = 'DRAFT';

  update public.customer_schedule_versions
  set
    status = 'SUPERSEDED',
    effective_until = case
      when effective_from < public.current_business_date()
        then least(coalesce(effective_until, public.current_business_date() - 1), public.current_business_date() - 1)
      else effective_until
    end,
    superseded_at = now(),
    superseded_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, 'Customer deactivated: ' || trim(p_reason)),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and status = 'PUBLISHED';

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'DEACTIVATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_reason),
    p_source_application
  );

  return v_customer;
end;
$function$;

-- get_customer_kg_history(p_customer_id uuid, p_from_date date, p_to_date date, p_recent_limit integer)
CREATE OR REPLACE FUNCTION public.get_customer_kg_history(p_customer_id uuid, p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_recent_limit integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_from date:=coalesce(p_from_date,current_date-interval '18 months');
  v_to date:=coalesce(p_to_date,current_date);
  v_limit integer:=least(greatest(coalesce(p_recent_limit,8),1),12);
  v_result jsonb;
begin
  if auth.uid() is null or not (
    public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null)
    or public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR'])
  ) then
    raise exception using errcode='42501',message='This account cannot view customer KG history.';
  end if;
  if p_customer_id is null then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if v_from>v_to or v_to-v_from>1827 then
    raise exception using errcode='22023',message='Choose a valid date range of no more than five years.';
  end if;
  if not exists(select 1 from public.customers c where c.customer_id=p_customer_id and c.deleted_at is null) then
    raise exception using errcode='P0002',message='Customer not found.';
  end if;

  with daily as (
    select a.actual_date,a.customer_id,max(a.customer_code) customer_code,max(a.customer_name) customer_name,
      a.product_code,extract(isodow from a.actual_date)::integer production_weekday,
      round(sum(a.actual_kg),2) actual_kg,
      string_agg(distinct a.production_source,', ' order by a.production_source) production_source
    from public.production_official_actuals a
    where a.customer_id=p_customer_id and a.actual_date between v_from and v_to
    group by a.actual_date,a.customer_id,a.product_code
  ), services as (
    select h.* from public.customer_kg_service_history(v_to+1,p_customer_id) h where h.recency_rank<=greatest(v_limit,8)
  ), estimates as (
    select e.* from public.customer_kg_estimates(v_to+1,p_customer_id) e
  )
  select jsonb_build_object(
    'customer',coalesce((select jsonb_build_object(
      'customer_id',customer_id,'customer_code',customer_code,'customer_name',customer_name
    ) from daily limit 1),(select jsonb_build_object(
      'customer_id',c.customer_id,'customer_code',c.customer_code,'customer_name',c.customer_name
    ) from public.customers c where c.customer_id=p_customer_id)),
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'policy',jsonb_build_object(
      'recent_records',8,'minimum_records',3,'method','RECENT_SERVICES_CAPPED_AVERAGE',
      'official_sources',jsonb_build_array('FINISH','MOP'),
      'message','Expected KG is calculated automatically: average of the latest 8 official services for the same customer, product and weekday (production finished up to two days later counts towards the same service; each service capped at 0.4x-2x the median).'
    ),
    'suggestions',coalesce((select jsonb_agg(jsonb_build_object(
      'product_code',e.product_code,'production_weekday',e.production_weekday,
      'history_points',e.history_points,
      'suggested_kg',e.estimated_kg,
      'observed_average_kg',e.estimated_kg,'median_kg',e.median_kg,'minimum_kg',e.minimum_kg,'maximum_kg',e.maximum_kg,
      'last_actual_date',e.last_service_date,'last_actual_kg',e.last_service_kg,
      'carried_over_points',e.carried_over_points,
      'recent_records',coalesce((select jsonb_agg(jsonb_build_object(
        'actual_date',s.service_date,'actual_kg',s.service_kg,'production_days',s.production_days,'carried_over',s.carried_over
      ) order by s.service_date desc) from services s
        where s.product_code=e.product_code and s.production_weekday=e.production_weekday and s.recency_rank<=8),'[]'::jsonb),
      'status',case when e.estimate_status='STALE' then 'READY' else e.estimate_status end,
      'estimate_status',e.estimate_status
    ) order by e.production_weekday,e.product_code) from estimates e),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object(
      'actual_date',d.actual_date,'production_weekday',d.production_weekday,'product_code',d.product_code,
      'actual_kg',d.actual_kg,'production_source',d.production_source
    ) order by d.actual_date desc,d.product_code) from daily d),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;

-- get_customer_master_record(p_customer_id uuid, p_effective_date date)
CREATE OR REPLACE FUNCTION public.get_customer_master_record(p_customer_id uuid, p_effective_date date DEFAULT current_business_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_result jsonb;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to maintain Customer Master records.';
  end if;

  if p_customer_id is null then
    raise exception using
      errcode = '22004',
      message = 'Customer ID is required.';
  end if;

  select jsonb_build_object(
    'customer_id', c.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'eircode', c.eircode,
    'distribution_estimated_kg', c.distribution_estimated_kg,
    'distribution_stop_count', c.distribution_stop_count,
    'notes', c.notes,
    'operational_alert', c.operational_alert,
    'active', c.active,
    'deactivated_at', c.deactivated_at,
    'deactivation_reason', c.deactivation_reason,
    'row_version', c.row_version,
    'created_at', c.created_at,
    'updated_at', c.updated_at,
    'product_services', coalesce(
      (
        select array_agg(
          pt.product_code
          order by pt.sort_order, pt.product_code
        )
        from public.customer_product_services cps
        join public.product_types pt
          on pt.product_type_id = cps.product_type_id
        where cps.customer_id = c.customer_id
          and cps.active = true
          and cps.deleted_at is null
          and cps.effective_from <= p_effective_date
          and (
            cps.effective_until is null
            or cps.effective_until >= p_effective_date
          )
          and pt.active = true
          and pt.deleted_at is null
      ),
      array[]::text[]
    )
  )
  into v_result
  from public.customers c
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if v_result is null then
    raise exception using
      errcode = 'P0002',
      message = 'Customer not found.';
  end if;

  return v_result;
end;
$function$;

-- get_customer_master_reference_data()
CREATE OR REPLACE FUNCTION public.get_customer_master_reference_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  );

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_edit_customers', public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']),
    'can_deactivate_customers', public.account_module_allowed(array['CUSTOMERS'],'MANAGE',array['ADMIN', 'MANAGER']),
    'product_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_type_id', pt.product_type_id,
            'product_code', pt.product_code,
            'display_name', pt.display_name,
            'sort_order', pt.sort_order
          )
          order by pt.sort_order, pt.display_name
        )
        from public.product_types pt
        where pt.active = true
          and pt.deleted_at is null
      ),
      '[]'::jsonb
    )
  );
end;
$function$;

-- get_customer_overview(p_customer_id uuid, p_effective_date date)
CREATE OR REPLACE FUNCTION public.get_customer_overview(p_customer_id uuid, p_effective_date date DEFAULT current_business_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  );

  if p_customer_id is null then
    raise exception using errcode = '22004', message = 'Customer ID is required.';
  end if;

  select jsonb_build_object(
    'customer_id', c.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'eircode', c.eircode,
    'notes', c.notes,
    'operational_alert', c.operational_alert,
    'active', c.active,
    'deactivated_at', c.deactivated_at,
    'deactivation_reason', c.deactivation_reason,
    'created_at', c.created_at,
    'updated_at', c.updated_at,
    'row_version', c.row_version,
    'effective_date', p_effective_date,
    'product_services', coalesce(services.product_services, array[]::text[]),
    'current_schedule', case
      when cv.schedule_version_id is null then null
      else jsonb_build_object(
        'schedule_version_id', cv.schedule_version_id,
        'version_number', cv.version_number,
        'status', cv.status,
        'effective_from', cv.effective_from,
        'effective_until', cv.effective_until,
        'source_code', cv.source_code,
        'change_reason', cv.change_reason,
        'published_at', cv.published_at,
        'schedule_day_count', coalesce(counts.schedule_day_count, 0),
        'schedule_product_count', coalesce(counts.schedule_product_count, 0)
      )
    end,
    'can_view_distribution', public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array[
        'ADMIN', 'MANAGER', 'PLANNER',
        'DISTRIBUTION_OPERATOR', 'AUDITOR'
      ])
  )
  into v_result
  from public.customers c
  left join lateral (
    select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
      as product_services
    from public.customer_product_services s
    join public.product_types pt
      on pt.product_type_id = s.product_type_id
    where s.customer_id = c.customer_id
      and s.active = true
      and s.deleted_at is null
      and s.effective_from <= p_effective_date
      and (s.effective_until is null or s.effective_until >= p_effective_date)
      and pt.active = true
      and pt.deleted_at is null
  ) services on true
  left join lateral (
    select v.*
    from public.customer_schedule_versions v
    where v.customer_id = c.customer_id
      and v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
    order by v.effective_from desc, v.version_number desc
    limit 1
  ) cv on true
  left join lateral (
    select
      count(distinct d.schedule_day_id)::integer as schedule_day_count,
      count(p.schedule_product_id)::integer as schedule_product_count
    from public.customer_schedule_days d
    left join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
     and p.active = true
    where d.schedule_version_id = cv.schedule_version_id
      and d.active = true
  ) counts on true
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if v_result is null then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  return v_result;
end;
$function$;

-- get_customer_read_capabilities()
CREATE OR REPLACE FUNCTION public.get_customer_read_capabilities()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_can_manage_schedules boolean;
  v_can_view_distribution boolean;
  v_pending_reports integer := 0;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR',
      'DISTRIBUTION_OPERATOR'
    ]
  );
  v_can_manage_schedules := public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']);
  v_can_view_distribution := public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR','AUDITOR']);
  if v_can_manage_schedules then
    select count(*)::integer into v_pending_reports
    from public.operational_data_reports where status='PENDING';
  end if;

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_view_customer_directory', public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_edit_customers', public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR']),
    'can_deactivate_customers', public.account_module_allowed(array['CUSTOMERS'],'MANAGE',array['ADMIN','MANAGER','DISTRIBUTION_OPERATOR']),
    'can_edit_schedules', v_can_manage_schedules,
    'can_create_schedule_draft', v_can_manage_schedules,
    'can_save_schedule_draft', v_can_manage_schedules,
    'can_compare_schedule_draft', v_can_manage_schedules,
    'can_publish_schedule_draft', v_can_manage_schedules,
    'can_cancel_schedule_draft', v_can_manage_schedules,
    'can_restore_schedule_version', v_can_manage_schedules,
    'can_view_schedule_history', public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_clothes_planner', public.account_module_allowed(array['CUSTOMERS','SORTING','FINISH'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','SORTING_OPERATOR','FINISH_OPERATOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_mop_planner', public.account_module_allowed(array['CUSTOMERS','MOP'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','MOP_OPERATOR','AUDITOR','DISTRIBUTION_OPERATOR']),
    'can_view_distribution', v_can_view_distribution,
    'can_view_operational_reports', v_can_manage_schedules,
    'can_review_operational_reports', v_can_manage_schedules,
    'pending_operational_report_count', v_pending_reports
  );
end;
$function$;

-- get_customer_schedule_history(p_customer_id uuid, p_selected_version_id uuid, p_effective_date date, p_limit integer)
CREATE OR REPLACE FUNCTION public.get_customer_schedule_history(p_customer_id uuid, p_selected_version_id uuid DEFAULT NULL::uuid, p_effective_date date DEFAULT current_business_date(), p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_customer record;
  v_current_version_id uuid;
  v_selected_version_id uuid;
  v_open_draft_version_id uuid;
  v_change_base_version_id uuid;
  v_versions jsonb;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_can_restore boolean;
begin
  perform public.require_customer_schedule_history_role();

  select
    c.customer_id,
    c.customer_code,
    c.customer_name,
    c.active
  into v_customer
  from public.customers c
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Customer not found.';
  end if;

  select v.schedule_version_id
  into v_current_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'PUBLISHED'
    and p_effective_date >= v.effective_from
    and (
      v.effective_until is null
      or p_effective_date <= v.effective_until
    )
  order by v.effective_from desc, v.version_number desc
  limit 1;

  select v.schedule_version_id
  into v_open_draft_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'DRAFT'
  order by v.created_at desc
  limit 1;

  if p_selected_version_id is not null then
    select v.schedule_version_id
    into v_selected_version_id
    from public.customer_schedule_versions v
    where v.schedule_version_id = p_selected_version_id
      and v.customer_id = p_customer_id;

    if v_selected_version_id is null then
      raise exception using
        errcode = '22023',
        message = 'The selected schedule revision does not belong to this customer.';
    end if;
  else
    select v.schedule_version_id
    into v_selected_version_id
    from public.customer_schedule_versions v
    where v.customer_id = p_customer_id
    order by
      case when v.schedule_version_id = v_current_version_id then 0 else 1 end,
      v.version_number desc
    limit 1;
  end if;

  if v_selected_version_id is not null then
    select v.based_on_version_id
    into v_change_base_version_id
    from public.customer_schedule_versions v
    where v.schedule_version_id = v_selected_version_id;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'schedule_version_id', history.schedule_version_id,
        'version_number', history.version_number,
        'status', history.status,
        'display_status', history.display_status,
        'is_current', history.schedule_version_id = v_current_version_id,
        'is_selected', history.schedule_version_id = v_selected_version_id,
        'effective_from', history.effective_from,
        'effective_until', history.effective_until,
        'source_code', history.source_code,
        'change_reason', history.change_reason,
        'general_instructions', history.general_instructions,
        'based_on_version_id', history.based_on_version_id,
        'restored_from_version_id', history.restored_from_version_id,
        'created_at', history.created_at,
        'updated_at', history.updated_at,
        'published_at', history.published_at,
        'cancelled_at', history.cancelled_at,
        'changed_by_name', history.changed_by_name,
        'day_count', history.day_count,
        'product_count', history.product_count,
        'trolley_requirement_count', history.trolley_requirement_count,
        'trolley_quantity', history.trolley_quantity
      )
      order by history.version_number desc
    ),
    '[]'::jsonb
  )
  into v_versions
  from (
    select
      v.schedule_version_id,
      v.version_number,
      v.status,
      case
        when v.schedule_version_id = v_current_version_id then 'CURRENT'
        when v.status = 'SUPERSEDED' then 'PREVIOUS'
        when v.status = 'DRAFT' then 'PENDING'
        when v.status = 'CANCELLED' then 'DISCARDED'
        else v.status
      end as display_status,
      v.effective_from,
      v.effective_until,
      v.source_code,
      v.change_reason,
      v.general_instructions,
      v.based_on_version_id,
      v.restored_from_version_id,
      v.created_at,
      v.updated_at,
      v.published_at,
      v.cancelled_at,
      coalesce(
        published_staff.display_name,
        cancelled_staff.display_name,
        updated_staff.display_name,
        created_staff.display_name,
        'System'
      ) as changed_by_name,
      coalesce(counts.day_count, 0) as day_count,
      coalesce(counts.product_count, 0) as product_count,
      coalesce(counts.trolley_requirement_count, 0) as trolley_requirement_count,
      coalesce(counts.trolley_quantity, 0) as trolley_quantity
    from public.customer_schedule_versions v
    left join public.staff_members created_staff
      on created_staff.auth_user_id = v.created_by
    left join public.staff_members updated_staff
      on updated_staff.auth_user_id = v.updated_by
    left join public.staff_members published_staff
      on published_staff.auth_user_id = v.published_by
    left join public.staff_members cancelled_staff
      on cancelled_staff.auth_user_id = v.cancelled_by
    left join lateral (
      select
        (
          select count(*)::integer
          from public.customer_schedule_days d
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as day_count,
        (
          select count(*)::integer
          from public.customer_schedule_products p
          join public.customer_schedule_days d
            on d.schedule_day_id = p.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as product_count,
        (
          select count(*)::integer
          from public.customer_schedule_trolley_requirements req
          join public.customer_schedule_days d
            on d.schedule_day_id = req.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as trolley_requirement_count,
        (
          select coalesce(sum(req.quantity), 0)::integer
          from public.customer_schedule_trolley_requirements req
          join public.customer_schedule_days d
            on d.schedule_day_id = req.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as trolley_quantity
    ) counts on true
    where v.customer_id = p_customer_id
    order by v.version_number desc
    limit v_limit
  ) history;

  v_can_restore := v_customer.active
    and v_open_draft_version_id is null
    and public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']);

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'effective_date', p_effective_date,
    'customer', jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'active', v_customer.active
    ),
    'permissions', jsonb_build_object(
      'can_view_history', true,
      'can_restore_version', v_can_restore
    ),
    'open_working_revision_id', v_open_draft_version_id,
    'current_version_id', v_current_version_id,
    'selected_version_id', v_selected_version_id,
    'versions', v_versions,
    'current_schedule', case
      when v_current_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_current_version_id
      )
    end,
    'selected_schedule', case
      when v_selected_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_selected_version_id
      )
    end,
    'change_base_version_id', v_change_base_version_id,
    'change_comparison', case
      when v_selected_version_id is null then null
      else public.build_customer_schedule_version_comparison(
        v_change_base_version_id,
        v_selected_version_id
      )
    end,
    'restore_comparison', case
      when v_selected_version_id is null
        or v_selected_version_id = v_current_version_id then null
      else public.build_customer_schedule_version_comparison(
        v_current_version_id,
        v_selected_version_id
      )
    end,
    -- Backward-compatible alias used by older frontend packages.
    'comparison', case
      when v_selected_version_id is null
        or v_selected_version_id = v_current_version_id then null
      else public.build_customer_schedule_version_comparison(
        v_current_version_id,
        v_selected_version_id
      )
    end
  );
end;
$function$;

-- get_customer_weekly_schedule(p_customer_id uuid, p_effective_date date)
CREATE OR REPLACE FUNCTION public.get_customer_weekly_schedule(p_customer_id uuid, p_effective_date date DEFAULT current_business_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_management boolean;
  v_clothes boolean;
  v_mop boolean;
  v_customer public.customers%rowtype;
  v_version public.customer_schedule_versions%rowtype;
  v_result jsonb;
begin
  v_management := public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']);
  v_clothes := v_management or public.account_module_allowed(array['SORTING','FINISH'],'VIEW',array['SORTING_OPERATOR', 'FINISH_OPERATOR']);
  v_mop := v_management or public.account_module_allowed(array['MOP'],'VIEW',array['MOP_OPERATOR']);

  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR', 'DISTRIBUTION_OPERATOR'
    ]
  );

  select * into v_customer
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  if not v_management and not v_customer.active then
    raise exception using errcode = '42501', message = 'Inactive customers are not available in operational views.';
  end if;

  select * into v_version
  from public.customer_schedule_versions
  where customer_id = p_customer_id
    and status = 'PUBLISHED'
    and p_effective_date >= effective_from
    and (effective_until is null or p_effective_date <= effective_until)
  order by effective_from desc, version_number desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'effective_date', p_effective_date,
      'schedule_version', null,
      'visible_product_codes', array_remove(array[
        case when v_clothes then 'CLOTHES' end,
        case when v_mop then 'MOP' end
      ], null),
      'days', '[]'::jsonb
    );
  end if;

  with visible_products as (
    select
      d.schedule_day_id,
      p.schedule_product_id,
      pt.product_code,
      pt.display_name as product_name,
      pt.sort_order as product_sort_order,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions,
      coalesce(variants.variant_names, array[]::text[]) as product_variants,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown,
      coalesce(trolley.has_shared_trolley, false) as has_shared_trolley
    from public.customer_schedule_days d
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
     and p.active = true
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
     and pt.active = true
     and pt.deleted_at is null
    left join lateral (
      select array_agg(pv.display_name order by pv.sort_order, pv.display_name)
        as variant_names
      from public.customer_schedule_product_variants spv
      join public.product_variants pv
        on pv.product_variant_id = spv.product_variant_id
      where spv.schedule_product_id = p.schedule_product_id
        and pv.active = true
        and pv.deleted_at is null
    ) variants on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            case when req.empty_trolley then ' Empty' else '' end
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'schedule_trolley_requirement_id', req.schedule_trolley_requirement_id,
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'shared', served.product_count > 1,
            'serves_product_codes', served.product_codes,
            'notes', req.notes
          )
          order by tt.sort_order, req.created_at
        ) as trolley_breakdown,
        bool_or(served.product_count > 1) as has_shared_trolley
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      left join lateral (
        select
          count(*)::integer as product_count,
          coalesce(
            jsonb_agg(pt2.product_code order by pt2.sort_order, pt2.product_code),
            '[]'::jsonb
          ) as product_codes
        from public.customer_schedule_trolley_requirement_products map
        join public.customer_schedule_products mapped_product
          on mapped_product.schedule_product_id = map.schedule_product_id
        join public.product_types pt2
          on pt2.product_type_id = mapped_product.product_type_id
        where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
      ) served on true
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where d.schedule_version_id = v_version.schedule_version_id
      and d.active = true
      and (
        (pt.product_code = 'CLOTHES' and v_clothes)
        or (pt.product_code = 'MOP' and v_mop)
      )
  ),
  day_payload as (
    select
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      d.day_alert,
      route_visual.route_color as route_visual_color,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'schedule_product_id', vp.schedule_product_id,
            'product_code', vp.product_code,
            'product_name', vp.product_name,
            'production_order', vp.production_order,
            'expected_kg', vp.expected_kg,
            'expected_units', vp.expected_units,
            'production_instructions', vp.production_instructions,
            'product_variants', vp.product_variants,
            'planned_trolley_total', vp.planned_trolley_total,
            'trolley_summary', vp.trolley_summary,
            'trolley_breakdown', vp.trolley_breakdown,
            'has_shared_trolley', vp.has_shared_trolley
          )
          order by vp.product_sort_order, vp.production_order nulls last
        ) filter (where vp.schedule_product_id is not null),
        '[]'::jsonb
      ) as products,
      coalesce(sum(vp.planned_trolley_total), 0)::integer as visible_trolley_total
    from public.customer_schedule_days d
    join visible_products vp
      on vp.schedule_day_id = d.schedule_day_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
    where d.schedule_version_id = v_version.schedule_version_id
      and d.active = true
    group by
      d.schedule_day_id,
      d.production_weekday,
      d.day_alert,
      route_visual.route_color
  )
  select jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_name', v_customer.customer_name,
    'active', v_customer.active,
    'operational_alert', v_customer.operational_alert,
    'effective_date', p_effective_date,
    'visible_product_codes', array_remove(array[
      case when v_clothes then 'CLOTHES' end,
      case when v_mop then 'MOP' end
    ], null),
    'schedule_version', jsonb_build_object(
      'schedule_version_id', v_version.schedule_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'effective_from', v_version.effective_from,
      'effective_until', v_version.effective_until,
      'source_code', v_version.source_code,
      'change_reason', v_version.change_reason,
      'general_instructions', v_version.general_instructions,
      'published_at', v_version.published_at
    ),
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'schedule_day_id', dp.schedule_day_id,
            'production_weekday', dp.production_weekday,
            'production_day', dp.production_day,
            'day_alert', dp.day_alert,
            'route_visual_color', dp.route_visual_color,
            'visible_trolley_total', dp.visible_trolley_total,
            'products', dp.products
          )
          order by dp.production_weekday
        )
        from day_payload dp
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$function$;

-- get_distribution_actuals_week(p_week_start date)
CREATE OR REPLACE FUNCTION public.get_distribution_actuals_week(p_week_start date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_roster_id uuid;
begin
  perform public.require_distribution_read_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'Select a Monday as the Distribution actuals week start.';
  end if;

  select distribution_roster_version_id into v_roster_id
  from public.distribution_roster_versions
  where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED')
  order by case roster_status when 'PUBLISHED' then 0 else 1 end, version_number desc
  limit 1;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'can_manage', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'drivers', coalesce((
      with planned as (
        select e.primary_driver_id as driver_id,
          sum(case when e.assignment_status = 'TRAINING' then 8 else coalesce(r.default_hours, 0) end)::numeric(8,2) as planned_hours
        from public.distribution_roster_entries e
        left join public.distribution_routes r on r.route_id = e.route_id
        where e.distribution_roster_version_id = v_roster_id and e.primary_driver_id is not null
        group by e.primary_driver_id
      )
      select jsonb_agg(jsonb_build_object(
        'driver_id', d.driver_id,
        'driver_code', d.driver_code,
        'display_name', d.display_name,
        'planned_hours', coalesce(p.planned_hours, 0),
        'actual_hours', a.actual_hours,
        'notes', a.notes,
        'updated_at', a.updated_at
      ) order by d.display_name)
      from public.distribution_drivers d
      left join planned p on p.driver_id = d.driver_id
      left join public.distribution_driver_weekly_actuals a on a.week_start = v_week_start and a.driver_id = d.driver_id
      where d.deleted_at is null and d.employment_status = 'ACTIVE'
    ), '[]'::jsonb),
    'vehicles', coalesce((
      with planned as (
        select e.vehicle_id,
          sum(coalesce(r.default_km, 0))::numeric(12,1) as planned_km
        from public.distribution_roster_entries e
        left join public.distribution_routes r on r.route_id = e.route_id
        where e.distribution_roster_version_id = v_roster_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
        group by e.vehicle_id
      )
      select jsonb_agg(jsonb_build_object(
        'vehicle_id', v.vehicle_id,
        'registration_number', v.registration_number,
        'display_name', v.display_name,
        'vehicle_type', v.vehicle_type,
        'planned_km', coalesce(p.planned_km, 0),
        'actual_km', m.actual_km,
        'odometer_km', coalesce(m.odometer_km, v.odometer_km),
        'current_odometer_km', v.odometer_km,
        'notes', m.notes,
        'updated_at', m.updated_at
      ) order by v.registration_number)
      from public.fleet_vehicles v
      left join planned p on p.vehicle_id = v.vehicle_id
      left join public.distribution_vehicle_weekly_mileage m on m.week_start = v_week_start and m.vehicle_id = v.vehicle_id
      where v.deleted_at is null and v.active
    ), '[]'::jsonb)
  );
end;
$function$;

-- get_distribution_operations_capabilities()
CREATE OR REPLACE FUNCTION public.get_distribution_operations_capabilities()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'can_view_distribution_operations', public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']),
    'can_plan_runs', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_dispatch_runs', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_record_stop_outcomes', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_manage_drivers', public.account_module_allowed(array['DISTRIBUTION'],'MANAGE',array['ADMIN','MANAGER','SUPERVISOR']),
    'can_manage_fleet', public.account_module_allowed(array['DISTRIBUTION'],'MANAGE',array['ADMIN','MANAGER','SUPERVISOR']),
    'can_manage_routes', public.account_module_allowed(array['DISTRIBUTION'],'MANAGE',array['ADMIN','MANAGER','SUPERVISOR'])
  );
$function$;

-- get_distribution_roster_context(p_week_start date)
CREATE OR REPLACE FUNCTION public.get_distribution_roster_context(p_week_start date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_week date := p_week_start;
  v_version public.distribution_roster_versions%rowtype;
  v_can_manage boolean;
begin
  perform public.require_distribution_roster_read_access();

  if v_week is null or extract(isodow from v_week) <> 1 then
    raise exception 'Week start must be a Monday.' using errcode='22023';
  end if;

  v_can_manage := public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR']);

  select * into v_version
  from public.distribution_roster_versions
  where week_start=v_week
    and roster_status in ('DRAFT','PUBLISHED')
  order by case roster_status when 'DRAFT' then 0 else 1 end,
           version_number desc
  limit 1;

  return jsonb_build_object(
    'schema','DISTRIBUTION_ROSTER_V1',
    'week_start',v_week,
    'week_end',v_week+6,
    'permissions',jsonb_build_object(
      'can_view',true,
      'can_manage',v_can_manage,
      'can_publish',v_can_manage
    ),
    'version',case
      when v_version.distribution_roster_version_id is null then null
      else jsonb_build_object(
        'roster_version_id',v_version.distribution_roster_version_id,
        'version_number',v_version.version_number,
        'status',v_version.roster_status,
        'row_version',v_version.row_version,
        'notes',v_version.roster_note,
        'published_at',v_version.published_at,
        'based_on_version_id',v_version.based_on_version_id
      )
    end,
    'drivers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'driver_id',d.driver_id,
        'driver_code',d.driver_code,
        'display_name',d.display_name,
        'licence_categories',d.licence_categories,
        'employment_status',d.employment_status,
        'availability_status',d.availability_status,
        'joined_on',d.joined_on,
        'deactivated_on',d.deactivated_on,
        'roster_hidden',d.roster_hidden
      ) order by lower(d.display_name))
      from public.distribution_drivers d
      where d.deleted_at is null
        and d.employment_status='ACTIVE'
        and not coalesce(d.roster_hidden,false)
        and (d.joined_on is null or d.joined_on <= v_week+6)
        and (d.deactivated_on is null or d.deactivated_on >= v_week)
    ),'[]'::jsonb),
    'routes_by_day',(
      select jsonb_object_agg(day_date::text,routes)
      from (
        select day_date,
          coalesce((
            select jsonb_agg(jsonb_build_object(
              'route_id',r.route_id,
              'route_code',r.route_code,
              'display_name',r.display_name,
              'route_color',coalesce(r.route_color,'#94A3B8'),
              'route_kind',r.route_kind,
              'default_km',coalesce(r.default_km,0),
              'default_hours',coalesce(r.default_hours,0)
            ) order by r.sort_order,r.route_code)
            from public.distribution_routes r
            where public.distribution_route_valid_on_date(r.route_id,day_date)
          ),'[]'::jsonb) routes
        from generate_series(v_week,v_week+6,interval '1 day') g(day_ts)
        cross join lateral (select day_ts::date day_date) x
      ) q
    ),
    'vehicles',coalesce((
      select jsonb_agg(jsonb_build_object(
        'vehicle_id',v.vehicle_id,
        'registration_number',v.registration_number,
        'display_name',v.display_name,
        'vehicle_type',v.vehicle_type,
        'operational_status',v.operational_status,
        'active',v.active,
        'service_due_on',v.service_due_on,
        'test_expires_on',v.test_expires_on,
        'road_tax_expires_on',v.road_tax_expires_on,
        'tacho_calibration_due_on',v.tacho_calibration_due_on,
        'tail_lift_weight_test_due_on',v.tail_lift_weight_test_due_on,
        'tail_lift_loler_due_on',v.tail_lift_loler_due_on,
        'open_defect_count',(
          select count(*)
          from public.fleet_vehicle_defects fd
          where fd.vehicle_id=v.vehicle_id
            and fd.defect_status='OPEN'
        )
      ) order by v.vehicle_type,v.registration_number)
      from public.fleet_vehicles v
      where v.deleted_at is null
        and lower(coalesce(v.legacy_status,'')) <> 'returned'
    ),'[]'::jsonb),
    'vehicle_day_status',(
      select jsonb_object_agg(day_date::text,statuses)
      from (
        select day_date,
          coalesce((
            select jsonb_agg(jsonb_build_object(
              'vehicle_id',v.vehicle_id,
              'block_reason',public.distribution_vehicle_block_reason(v.vehicle_id,day_date),
              'borderline',(
                public.distribution_vehicle_block_reason(v.vehicle_id,day_date) is null
                and least(
                  coalesce(v.service_due_on,'9999-12-31'::date),
                  coalesce(v.test_expires_on,'9999-12-31'::date),
                  coalesce(v.road_tax_expires_on,'9999-12-31'::date),
                  coalesce(v.tacho_calibration_due_on,'9999-12-31'::date),
                  coalesce(v.tail_lift_weight_test_due_on,'9999-12-31'::date),
                  coalesce(v.tail_lift_loler_due_on,'9999-12-31'::date)
                ) between day_date and day_date+30
              ),
              'warning_date',least(
                coalesce(v.service_due_on,'9999-12-31'::date),
                coalesce(v.test_expires_on,'9999-12-31'::date),
                coalesce(v.road_tax_expires_on,'9999-12-31'::date),
                coalesce(v.tacho_calibration_due_on,'9999-12-31'::date),
                coalesce(v.tail_lift_weight_test_due_on,'9999-12-31'::date),
                coalesce(v.tail_lift_loler_due_on,'9999-12-31'::date)
              )
            ))
            from public.fleet_vehicles v
            where v.deleted_at is null
              and lower(coalesce(v.legacy_status,'')) <> 'returned'
          ),'[]'::jsonb) statuses
        from generate_series(v_week,v_week+6,interval '1 day') g(day_ts)
        cross join lateral (select day_ts::date day_date) x
      ) q
    ),
    'absences',coalesce((
      select jsonb_agg(jsonb_build_object(
        'absence_id',a.absence_id,
        'driver_id',a.driver_id,
        'absence_type',a.absence_type,
        'starts_on',a.starts_on,
        'ends_on',a.ends_on,
        'absence_status',a.absence_status,
        'notes',a.notes
      ) order by a.starts_on,a.driver_id)
      from public.distribution_driver_absences a
      where a.absence_status='APPROVED'
        and a.starts_on <= v_week+6
        and a.ends_on >= v_week
    ),'[]'::jsonb),
    'entries',coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_entry_id',e.distribution_roster_entry_id,
        'driver_id',e.primary_driver_id,
        'work_date',e.work_date,
        'day_status',case when e.assignment_status='PLANNED' then 'WORKING' else e.assignment_status end,
        'route_id',e.route_id,
        'vehicle_id',e.vehicle_id,
        'driver_name_snapshot',e.primary_driver_name_snapshot,
        'route_code_snapshot',e.route_code_snapshot,
        'route_name_snapshot',e.route_name_snapshot,
        'route_color_snapshot',e.route_color_snapshot,
        'vehicle_registration_snapshot',e.vehicle_registration_snapshot,
        'vehicle_type_snapshot',coalesce(v.vehicle_type,null),
        'notes',e.entry_note
      ) order by e.work_date,lower(coalesce(e.primary_driver_name_snapshot,'')))
      from public.distribution_roster_entries e
      left join public.fleet_vehicles v on v.vehicle_id=e.vehicle_id
      where e.distribution_roster_version_id=v_version.distribution_roster_version_id
        and e.primary_driver_id is not null
    ),'[]'::jsonb)
  );
end;
$function$;

-- get_distribution_roster_week(p_week_start date, p_roster_version_id uuid)
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
    'drivers', coalesce((select jsonb_agg(to_jsonb(d) order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status = 'ACTIVE'), '[]'::jsonb),
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

-- get_finish_production_context(p_shift_code text, p_at timestamp with time zone)
CREATE OR REPLACE FUNCTION public.get_finish_production_context(p_shift_code text DEFAULT 'MORNING'::text, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_shift text:=upper(trim(coalesce(p_shift_code,'MORNING'))); v_now timestamptz:=coalesce(p_at,now()); v_business_date date;
  v_target numeric:=23.5; v_queue jsonb; v_entries jsonb; v_tables jsonb; v_staff jsonb;
begin
  perform public.require_finish_production_access();
  if v_shift not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift,v_now);
  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active=true limit 1),23.5) into v_target;

  with candidate as (
    select p.*,public.next_distribution_business_date(p.scheduled_for_date) delivery_date,public.finish_delivery_cutoff(public.next_distribution_business_date(p.scheduled_for_date)) cutoff
    from public.production_flow_items p
    where p.product_code='CLOTHES' and p.flow_status='OPEN' and p.scheduled_for_date is not null
      and public.next_distribution_business_date(p.scheduled_for_date)>=v_business_date
      and exists(select 1 from public.production_flow_events ev where ev.production_flow_item_id=p.production_flow_item_id and ev.stage_rank>=30 and ev.event_type like 'WASH%')
  ), totals as (
    select e.production_flow_item_id,
      coalesce(sum(case when l.unit_code='KG' then l.quantity else 0 end),0) processed_kg,
      coalesce(sum(case when l.unit_code='UNIT' then l.quantity else 0 end),0) processed_units,
      count(distinct e.entry_group_id) contribution_count,
      max(e.recorded_at) last_finish_at
    from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE' group by e.production_flow_item_id
  ), q as (
    select c.*,coalesce(t.processed_kg,0) processed_kg,coalesce(t.processed_units,0) processed_units,coalesce(t.contribution_count,0) contribution_count,t.last_finish_at,
      case when v_now>=c.cutoff then 'LOCKED' when coalesce(t.contribution_count,0)>0 then 'CONTINUE' else 'READY' end finish_state
    from candidate c left join totals t on t.production_flow_item_id=c.production_flow_item_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'production_flow_item_id',q.production_flow_item_id,'customer_id',q.customer_id,'customer_code',q.customer_code_snapshot,'customer_name',q.customer_name_snapshot,
    'scheduled_for_date',q.scheduled_for_date,'delivery_date',q.delivery_date,'edit_cutoff_at',q.cutoff,'production_order',q.production_order_snapshot,
    'route_code',q.route_code_snapshot,'route_name',q.route_display_name_snapshot,'route_color',q.route_color_snapshot,'finish_state',q.finish_state,
    'processed_kg',q.processed_kg,'processed_units',q.processed_units,'contribution_count',q.contribution_count,'last_finish_at',q.last_finish_at,
    'expected_kg',(select sp.expected_kg from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'expected_units',(select sp.expected_units from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'finish_instructions',(select sp.production_instructions from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'planned_trolley_summary',(select string_agg(concat(r.quantity,coalesce(tt.display_code,tt.trolley_type_code),case when r.empty_trolley then ' Empty' else '' end),' + ' order by tt.sort_order) from public.customer_schedule_trolley_requirements r join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id where r.active=true and r.owner_schedule_product_id=q.source_schedule_product_id),
    'planned_trolley_requirements',(select coalesce(jsonb_agg(jsonb_build_object('trolley_type_id',tt.trolley_type_id,'trolley_type_code',tt.trolley_type_code,'display_code',coalesce(tt.display_code,tt.trolley_type_code),'trolley_type_name',tt.trolley_type_name,'quantity',r.quantity,'empty_trolley',r.empty_trolley) order by tt.sort_order),'[]'::jsonb) from public.customer_schedule_trolley_requirements r join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id where r.active=true and r.owner_schedule_product_id=q.source_schedule_product_id)
  ) order by q.delivery_date,q.production_order_snapshot nulls last,q.customer_name_snapshot),'[]'::jsonb) into v_queue from q;

  with active as (
    select e.*,
      coalesce((select sum(l.quantity) from public.finish_production_lines l where l.finish_production_entry_id=e.finish_production_entry_id and l.unit_code='KG'),0) kg,
      coalesce((select sum(l.quantity) from public.finish_production_lines l where l.finish_production_entry_id=e.finish_production_entry_id and l.unit_code='UNIT'),0) units
    from public.finish_production_entries e where e.status='ACTIVE' and e.production_business_date between v_business_date-7 and v_business_date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'finish_production_entry_id',a.finish_production_entry_id,'entry_group_id',a.entry_group_id,'revision_no',a.revision_no,'production_flow_item_id',a.production_flow_item_id,
    'customer_id',a.customer_id,'customer_name',(select customer_name_snapshot from public.production_flow_items where production_flow_item_id=a.production_flow_item_id),
    'business_date',a.production_business_date,'delivery_date',a.delivery_date,'edit_cutoff_at',a.edit_cutoff_at,'shift_code',a.shift_code_snapshot,'table_code',a.table_code_snapshot,'table_name',a.table_name_snapshot,
    'processed_kg',a.kg,'processed_units',a.units,'notes',a.notes,'recorded_at',a.recorded_at,
    'recorded_by',(select display_name from public.staff_members where staff_id=a.recorded_by_staff_id),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('line_no',l.line_no,'batch_reference',l.batch_reference,'unit_code',l.unit_code,'quantity',l.quantity) order by l.line_no) from public.finish_production_lines l where l.finish_production_entry_id=a.finish_production_entry_id),'[]'::jsonb),
    'trolley_codes',coalesce((select jsonb_agg(t.trolley_code_snapshot order by t.trolley_code_snapshot) from public.finish_production_trolleys t where t.finish_production_entry_id=a.finish_production_entry_id),'[]'::jsonb)
  ) order by a.recorded_at desc),'[]'::jsonb) into v_entries from active a;

  with table_master as (
    select st.station_id,st.station_code,st.station_name from public.stations st join public.areas a on a.area_id=st.area_id where a.area_code='FINISH' and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') and st.active=true and st.deleted_at is null
  ), hours as (
    select tm.station_code,
      coalesce(sum(greatest(0,extract(epoch from (least(coalesce(ws.actual_end_at,v_now),v_now)-ws.actual_start_at))/3600.0 - coalesce(ws.break_minutes,0)/60.0)),0) staff_hours,
      count(distinct ws.staff_id) filter(where ws.actual_start_at is not null and (ws.actual_end_at is null or ws.actual_end_at>ws.actual_start_at)) staff_count
    from table_master tm left join public.work_sessions ws on ws.station_id=tm.station_id and ws.work_date=v_business_date and ws.status<>'CANCELLED'
      and ws.shift_id=(select shift_id from public.shifts where shift_code=v_shift and active=true and deleted_at is null)
    group by tm.station_code
  ), prod as (
    select e.table_code_snapshot station_code,coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) produced_kg,coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) produced_units
    from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_business_date and e.shift_code_snapshot=v_shift group by e.table_code_snapshot
  )
  select coalesce(jsonb_agg(jsonb_build_object('table_code',tm.station_code,'table_name',tm.station_name,'produced_kg',coalesce(p.produced_kg,0),'produced_units',coalesce(p.produced_units,0),'staff_hours',round(coalesce(h.staff_hours,0)::numeric,2),'staff_count',coalesce(h.staff_count,0),'target_kg_per_staff_hour',v_target,'target_now_kg',round((coalesce(h.staff_hours,0)*v_target)::numeric,2),'difference_kg',round((coalesce(p.produced_kg,0)-coalesce(h.staff_hours,0)*v_target)::numeric,2),'kg_per_staff_hour',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/h.staff_hours)::numeric,2) else null end,'efficiency_percent',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/(h.staff_hours*v_target)*100)::numeric,1) else null end) order by tm.station_code),'[]'::jsonb) into v_tables from table_master tm left join hours h on h.station_code=tm.station_code left join prod p on p.station_code=tm.station_code;

  with planned as (
    select distinct on (pre.staff_id) pre.staff_id,pre.staff_display_name_snapshot display_name,pre.station_code_snapshot planned_table_code,pre.planned_start_time,pre.planned_end_time
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    join public.shifts psh on psh.shift_id=prv.shift_id
    where prv.status='PUBLISHED' and pre.work_date=v_business_date and psh.shift_code=v_shift
      and pre.area_code_snapshot='FINISH' and pre.day_status in ('WORKING','QUALITY_ANALYSIS')
    order by pre.staff_id,prv.version_number desc
  ), actual as (
    select distinct on (ws.staff_id) ws.staff_id,ws.work_session_id,st.station_code table_code,ws.actual_start_at,ws.actual_end_at,ws.status,ws.source
    from public.work_sessions ws join public.areas a on a.area_id=ws.area_id join public.shifts sh on sh.shift_id=ws.shift_id left join public.stations st on st.station_id=ws.station_id
    where ws.work_date=v_business_date and ws.status<>'CANCELLED' and a.area_code='FINISH' and sh.shift_code=v_shift
    order by ws.staff_id,ws.updated_at desc
  ), ids as (select staff_id from planned union select staff_id from actual)
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,'display_name',sm.display_name,'planned_table_code',p.planned_table_code,'planned_start_time',p.planned_start_time,'planned_end_time',p.planned_end_time,
    'work_session_id',a.work_session_id,'table_code',a.table_code,'actual_start_at',a.actual_start_at,'actual_end_at',a.actual_end_at,'status',a.status,'source',a.source
  ) order by coalesce(a.table_code,p.planned_table_code,'ZZZ'),sm.display_name),'[]'::jsonb) into v_staff
  from ids i join public.staff_members sm on sm.staff_id=i.staff_id left join planned p on p.staff_id=i.staff_id left join actual a on a.staff_id=i.staff_id;

  return jsonb_build_object('schema_version','FINISH_PRODUCTION_V1','source_contract','FINISH_V2_PRODUCTION_LEDGER','generated_at',v_now,'business_date',v_business_date,'shift_code',v_shift,'target_kg_per_staff_hour',v_target,'queue',v_queue,'entries',v_entries,'tables',v_tables,'staff',v_staff,'permissions',jsonb_build_object('can_record',true,'can_select_any_table',public.account_module_allowed(array['FINISH'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR'])));
end;
$function$;

-- get_operational_area_incoming_staff(p_area_code text, p_shift_code text)
CREATE OR REPLACE FUNCTION public.get_operational_area_incoming_staff(p_area_code text, p_shift_code text DEFAULT 'MORNING'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$ declare v_area_code text := upper(trim(coalesce(p_area_code, ''))); v_shift_code text := upper(trim(coalesce(p_shift_code, ''))); v_business_date date := public.operational_business_date_for_shift(p_shift_code); v_area public.areas%rowtype; v_shift public.shifts%rowtype; v_rows jsonb := '[]'::jsonb; begin if auth.uid() is null then raise exception using errcode = '42501', message = 'Authentication is required.'; end if; if not public.account_module_allowed(array['SORTING','FINISH','MOP','DISTRIBUTION'],'VIEW',array[ 'ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR', 'FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR' ]) then raise exception using errcode = '42501', message = 'Operational staff access is required.'; end if; select * into v_area from public.areas a where a.area_code = v_area_code and a.active = true and a.deleted_at is null limit 1; if not found then raise exception using errcode = 'P0002', message = 'Selected operational area is not available.'; end if; select * into v_shift from public.shifts sh where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null limit 1; if not found then raise exception using errcode = 'P0002', message = 'Selected shift is not available.'; end if; select coalesce(jsonb_agg( jsonb_build_object( 'work_session_id', ws.work_session_id, 'staff_id', sm.staff_id, 'display_name', sm.display_name, 'business_date', ws.work_date, 'shift_code', v_shift.shift_code, 'planned_area_code', coalesce(nullif(pre.area_code_snapshot, ''), planned_area.area_code), 'planned_station_code', coalesce(nullif(pre.station_code_snapshot, ''), planned_station.station_code), 'actual_area_code', v_area.area_code, 'actual_area_name', v_area.area_name, 'actual_start_time', case when ws.actual_start_at is null then null else (ws.actual_start_at at time zone 'Europe/Dublin')::time end, 'actual_end_time', case when ws.actual_end_at is null then null else (ws.actual_end_at at time zone 'Europe/Dublin')::time end, 'source', ws.source, 'notes', ws.notes, 'updated_at', ws.updated_at ) order by lower(sm.display_name) ), '[]'::jsonb) into v_rows from public.work_sessions ws join public.staff_members sm on sm.staff_id = ws.staff_id left join public.production_roster_entries pre on pre.roster_entry_id = ws.production_roster_entry_id left join public.areas planned_area on planned_area.area_id = pre.area_id left join public.stations planned_station on planned_station.station_id = pre.station_id where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id and ws.area_id = v_area.area_id and ws.source = 'SORTING_AREA_TRANSFER' and ws.status <> 'CANCELLED'; return jsonb_build_object( 'business_date', v_business_date, 'shift_code', v_shift.shift_code, 'area_code', v_area.area_code, 'area_name', v_area.area_name, 'incoming_transfers', v_rows, 'source', 'WORK_SESSIONS_ACTUAL_AREA_TRANSFER' ); end; $function$;

-- get_production_roster_reference_data()
CREATE OR REPLACE FUNCTION public.get_production_roster_reference_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_production_roster_read_role();

  return jsonb_build_object(
    'can_manage', public.account_module_allowed(array['PRODUCTION_ROSTER'],'EDIT',array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']),
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shift_id', s.shift_id,
        'shift_code', s.shift_code,
        'shift_name', s.shift_name,
        'start_time', s.start_time,
        'end_time', s.end_time,
        'sort_order', s.sort_order
      ) order by s.sort_order, s.shift_name)
      from public.shifts s
      where s.active = true and s.deleted_at is null and s.shift_code in ('MORNING', 'EVENING')
    ), '[]'::jsonb),
    'operational_roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'role_code', r.role_code,
        'role_name', r.role_name,
        'allow_as_cover', r.allow_as_cover,
        'sort_order', r.sort_order
      ) order by r.sort_order, r.role_name)
      from public.operational_roles r
      where r.active = true and r.deleted_at is null
    ), '[]'::jsonb),
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'area_id', a.area_id,
        'area_code', a.area_code,
        'area_name', a.area_name,
        'sort_order', a.sort_order
      ) order by a.sort_order, a.area_name)
      from public.areas a
      where a.active = true and a.deleted_at is null
        and a.area_code in ('SORTING', 'FINISH', 'MOP', 'WASHING')
    ), '[]'::jsonb),
    'stations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'station_id', st.station_id,
        'area_id', st.area_id,
        'station_code', st.station_code,
        'station_name', st.station_name,
        'station_type', st.station_type,
        'sort_order', st.sort_order
      ) order by st.sort_order, st.station_name)
      from public.stations st
      where st.active = true and st.deleted_at is null
    ), '[]'::jsonb),
    'day_statuses', jsonb_build_array(
      jsonb_build_object('code', 'WORKING', 'name', 'Working', 'abbreviation', 'W'),
      jsonb_build_object('code', 'COVER', 'name', 'Cover', 'abbreviation', 'C'),
      jsonb_build_object('code', 'OFF', 'name', 'Off', 'abbreviation', 'O'),
      jsonb_build_object('code', 'SICK', 'name', 'Sick', 'abbreviation', 'S'),
      jsonb_build_object('code', 'HOLIDAY', 'name', 'Holiday', 'abbreviation', 'H'),
      jsonb_build_object('code', 'TRAINING', 'name', 'Training', 'abbreviation', 'T'),
      jsonb_build_object('code', 'QUALITY_ANALYSIS', 'name', 'Quality Analysis', 'abbreviation', 'QA')
    )
  );
end;
$function$;

-- get_production_roster_week(p_week_start date, p_shift_code text, p_roster_version_id uuid)
CREATE OR REPLACE FUNCTION public.get_production_roster_week(p_week_start date, p_shift_code text, p_roster_version_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_version public.production_roster_versions%rowtype;
  v_period_id uuid;
  v_can_manage boolean;
  v_is_past boolean := v_week_start < public.production_roster_week_start(current_date);
begin
  perform public.require_production_roster_read_role();
  v_can_manage := public.account_module_allowed(array['PRODUCTION_ROSTER'],'EDIT',array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']);

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start;

  if p_roster_version_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.roster_version_id = p_roster_version_id
      and rp.week_start = v_week_start
      and prv.shift_id = v_shift.shift_id;
  elsif v_period_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status in ('DRAFT', 'PUBLISHED')
    order by case prv.status when 'DRAFT' then 1 else 2 end, prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'is_past', v_is_past,
    'can_manage', v_can_manage,
    'shift', jsonb_build_object(
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name,
      'start_time', v_shift.start_time,
      'end_time', v_shift.end_time
    ),
    'document', case when v_version.roster_version_id is null then null else jsonb_build_object(
      'roster_version_id', v_version.roster_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'include_sunday', v_version.include_sunday,
      'week_note', v_version.week_note,
      'row_version', v_version.row_version,
      'based_on_version_id', v_version.based_on_version_id,
      'saved_at', v_version.saved_at,
      'published_at', v_version.published_at,
      'is_historical', p_roster_version_id is not null
    ) end,
    'published_document', (
      select jsonb_build_object(
        'roster_version_id', p.roster_version_id,
        'version_number', p.version_number,
        'published_at', p.published_at
      )
      from public.production_roster_versions p
      where p.roster_period_id = v_period_id
        and p.shift_id = v_shift.shift_id
        and p.status = 'PUBLISHED'
      limit 1
    ),
    'staff', case
      when v_version.roster_version_id is not null then coalesce((
        select jsonb_agg(staff_row order by
          (staff_row ->> 'display_section_sort')::integer,
          (staff_row ->> 'group_sort')::integer,
          (staff_row ->> 'station_sort')::integer,
          lower(staff_row ->> 'display_name')
        )
        from (
          select distinct on (pre.staff_id)
            jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'default_shift_code', coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot),
              'default_shift_name', coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot),
              'primary_role_code', coalesce(pre.staff_primary_role_code_snapshot, sm_role.role_code),
              'primary_role_name', coalesce(pre.staff_primary_role_name_snapshot, sm_role.role_name),
              'default_area_code', coalesce(pre.staff_default_area_code_snapshot, sm_area.area_code),
              'default_area_name', coalesce(pre.staff_default_area_name_snapshot, sm_area.area_name),
              'default_station_code', coalesce(pre.staff_default_station_code_snapshot, sm_station.station_code),
              'default_station_name', coalesce(pre.staff_default_station_name_snapshot, sm_station.station_name),
              'display_section_code', pre.display_section_code,
              'shift_override_authorized', exists (
                select 1
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
              ),
              'shift_override_source', (
                select pro.source_application
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
                limit 1
              ),
              'display_section_sort', public.production_roster_display_section_sort(pre.display_section_code),
              'fire_training', pre.fire_training_snapshot,
              'first_aid_training', pre.first_aid_training_snapshot,
              'eod_capable', pre.eod_capable_snapshot,
              'cover_role_codes', coalesce((
                select jsonb_agg(cr.role_code order by cr.sort_order)
                from public.staff_cover_capabilities scc
                join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
                where scc.staff_id = pre.staff_id
                  and scc.active = true
                  and scc.deleted_at is null
                  and scc.effective_from <= current_date
                  and (scc.effective_until is null or scc.effective_until >= current_date)
              ), '[]'::jsonb),
              'group_sort', coalesce(sm_role.sort_order, 999),
              'station_sort', coalesce(sm_station.sort_order, 999)
            ) as staff_row
          from public.production_roster_entries pre
          left join public.staff_members sm on sm.staff_id = pre.staff_id
          left join public.operational_roles sm_role on sm_role.operational_role_id = sm.primary_operational_role_id
          left join public.areas sm_area on sm_area.area_id = sm.default_area_id
          left join public.stations sm_station on sm_station.station_id = sm.default_station_id
          where pre.roster_version_id = v_version.roster_version_id
          order by pre.staff_id, pre.work_date
        ) rows
      ), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'staff_id', sm.staff_id,
          'display_name', sm.display_name,
          'employee_code', sm.employee_code,
          'default_shift_code', s.shift_code,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'display_section_code', public.production_roster_default_display_section(opr.role_code, st.station_code),
          'shift_override_authorized', false,
          'shift_override_source', null,
          'display_section_sort', public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'cover_role_codes', coalesce((
            select jsonb_agg(cr.role_code order by cr.sort_order)
            from public.staff_cover_capabilities scc
            join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.deleted_at is null
              and scc.effective_from <= v_week_start + 6
              and (scc.effective_until is null or scc.effective_until >= v_week_start)
          ), '[]'::jsonb),
          'group_sort', coalesce(opr.sort_order, 999),
          'station_sort', coalesce(st.sort_order, 999)
        ) order by
          public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          coalesce(opr.sort_order, 999),
          coalesce(st.sort_order, 999),
          lower(sm.display_name))
        from public.staff_members sm
        join public.shifts s on s.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.active = true
          and sm.roster_eligible = true
          and sm.deleted_at is null
          and (sm.production_roster_until is null or sm.production_roster_until >= v_week_start)
          and s.shift_id = v_shift.shift_id
      ), '[]'::jsonb)
    end,
    'entries', case when v_version.roster_version_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_entry_id', pre.roster_entry_id,
        'staff_id', pre.staff_id,
        'work_date', pre.work_date,
        'day_status', pre.day_status,
        'assignment_type', pre.assignment_type,
        'operational_role_code', opr.role_code,
        'operational_role_name', pre.operational_role_name_snapshot,
        'area_code', a.area_code,
        'area_name', pre.area_name_snapshot,
        'station_code', st.station_code,
        'station_name', pre.station_name_snapshot,
        'sorting_work_mode', pre.sorting_work_mode,
        'display_section_code', pre.display_section_code,
        'shift_override_confirmed', exists (
          select 1
          from public.production_roster_shift_overrides pro
          where pro.roster_version_id = pre.roster_version_id
            and pro.staff_id = pre.staff_id
        ),
        'planned_start_time', pre.planned_start_time,
        'planned_end_time', pre.planned_end_time,
        'notes', pre.notes
      ) order by pre.work_date, lower(pre.staff_display_name_snapshot))
      from public.production_roster_entries pre
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      where pre.roster_version_id = v_version.roster_version_id
    ), '[]'::jsonb) end
  );
end;
$function$;

-- get_sorting_mop_type_catalog()
CREATE OR REPLACE FUNCTION public.get_sorting_mop_type_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_types jsonb;
begin
  perform public.begin_mop_operational_scope();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_variant_id', pv.product_variant_id,
        'variant_code', pv.variant_code,
        'display_name', pv.display_name,
        'active', pv.active,
        'sort_order', pv.sort_order,
        'category', nullif(coalesce(pv.metadata->>'category', pv.metadata->>'type', ''), ''),
        'unit_weight_grams', case
          when coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams', '') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end,
        'image_url', nullif(coalesce(pv.metadata->>'image_url', pv.metadata->>'photo_url', ''), ''),
        'notes', nullif(coalesce(pv.metadata->>'notes', ''), ''),
        'source', nullif(coalesce(pv.metadata->>'source', ''), ''),
        'unit_weight_source', nullif(coalesce(pv.metadata->>'unit_weight_source', ''), ''),
        'unit_weight_evidence_count', case
          when coalesce(pv.metadata->>'unit_weight_evidence_count','') ~ '^[0-9]+$'
            then (pv.metadata->>'unit_weight_evidence_count')::integer
          else null
        end,
        'unit_weight_review_required', coalesce((pv.metadata->>'unit_weight_review_required')::boolean,false),
        'legacy_weight_observations', coalesce(pv.metadata->'legacy_weight_observations','{}'::jsonb),
        'schedule_link_count', coalesce(links.schedule_link_count, 0),
        'production_line_count', coalesce(prod.production_line_count, 0),
        'created_at', pv.created_at,
        'updated_at', pv.updated_at
      )
      order by pv.sort_order, pv.display_name, pv.variant_code
    ),
    '[]'::jsonb
  )
  into v_types
  from public.product_variants pv
  join public.product_types pt
    on pt.product_type_id = pv.product_type_id
   and pt.active = true
   and pt.deleted_at is null
   and pt.product_code = 'MOP'
  left join lateral (
    select count(*)::integer as schedule_link_count
    from public.customer_schedule_product_variants cspv
    where cspv.product_variant_id = pv.product_variant_id
  ) links on true
  left join lateral (
    select count(*)::integer as production_line_count
    from public.sorting_mop_production_lines mpl
    where mpl.product_variant_id = pv.product_variant_id
  ) prod on true
  where pv.deleted_at is null;

  return jsonb_build_object(
    'bucket_id', 'mop-type-photos',
    'max_file_bytes', 2097152,
    'allowed_mime_types', jsonb_build_array('image/jpeg','image/png','image/webp'),
    'can_manage', public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']),
    'can_create', public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']),
    'types', v_types
  );
end;
$function$;

-- get_staff_master_reference_data()
CREATE OR REPLACE FUNCTION public.get_staff_master_reference_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_staff_master_read_role();

  return jsonb_build_object(
    'business_date', current_date,
    'can_edit_staff', public.account_module_allowed(array['STAFF_MASTER'],'EDIT',array['ADMIN', 'MANAGER']),
    'can_deactivate_staff', public.account_module_allowed(array['STAFF_MASTER'],'MANAGE',array['ADMIN', 'MANAGER']),
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shift_id', s.shift_id,
        'shift_code', s.shift_code,
        'shift_name', s.shift_name,
        'start_time', s.start_time,
        'end_time', s.end_time,
        'sort_order', s.sort_order
      ) order by s.sort_order, s.shift_name)
      from public.shifts s
      where s.active = true and s.deleted_at is null
    ), '[]'::jsonb),
    'operational_roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operational_role_id', opr.operational_role_id,
        'role_code', opr.role_code,
        'role_name', opr.role_name,
        'allow_as_primary', opr.allow_as_primary,
        'allow_as_cover', opr.allow_as_cover,
        'sort_order', opr.sort_order
      ) order by opr.sort_order, opr.role_name)
      from public.operational_roles opr
      where opr.active = true and opr.deleted_at is null
    ), '[]'::jsonb),
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'area_id', a.area_id,
        'area_code', a.area_code,
        'area_name', a.area_name,
        'sort_order', a.sort_order
      ) order by a.sort_order, a.area_name)
      from public.areas a
      where a.active = true and a.deleted_at is null
    ), '[]'::jsonb),
    'stations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'station_id', s.station_id,
        'station_code', s.station_code,
        'station_name', s.station_name,
        'station_type', s.station_type,
        'area_id', s.area_id,
        'sort_order', s.sort_order
      ) order by a.sort_order, s.sort_order, s.station_name)
      from public.stations s
      join public.areas a on a.area_id = s.area_id
      where s.active = true and s.deleted_at is null
        and a.active = true and a.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$function$;

-- get_trolley_lifecycle_capabilities()
CREATE OR REPLACE FUNCTION public.get_trolley_lifecycle_capabilities()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'can_view_trolleys', public.account_module_allowed(array['TROLLEYS','SORTING','FINISH','MOP','DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR','SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR']),
    'can_assign_trolleys_from_production', public.account_module_allowed(array['TROLLEYS','FINISH','MOP'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR']),
    'can_assign_finish_trolleys', public.account_module_allowed(array['TROLLEYS','FINISH'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']),
    'can_assign_mop_trolleys', public.account_module_allowed(array['TROLLEYS','MOP'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR']),
    'can_view_distribution_handoff', public.account_module_allowed(array['TROLLEYS','DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']),
    'can_dispatch_trolleys', public.account_module_allowed(array['TROLLEYS'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR']),
    'can_receive_trolleys', public.account_module_allowed(array['TROLLEYS','SORTING'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']),
    'can_confirm_sorting_arrival', public.account_module_allowed(array['TROLLEYS','SORTING'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']),
    'can_view_trolley_exceptions', false,
    'can_review_trolley_exceptions', false,
    'trolley_exception_policy','HISTORY_ONLY',
    'can_manage_trolley_master', public.account_module_allowed(array['TROLLEYS'],'MANAGE',array['ADMIN','MANAGER']),
    'can_manage_trolley_types', public.account_module_allowed(array['TROLLEYS'],'MANAGE',array['ADMIN','MANAGER'])
  );
$function$;

-- get_trolley_reference_data()
CREATE OR REPLACE FUNCTION public.get_trolley_reference_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_warning_days integer;
  v_overdue_days integer;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  return jsonb_build_object(
    'capabilities', public.get_trolley_lifecycle_capabilities(),
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'delivery_tracking_mode', 'PRODUCTION_NEXT_DAY_INFERENCE',
    'customers', case
      when public.account_module_allowed(array['TROLLEYS','SORTING'],'VIEW',array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']) then
        coalesce(
          (
            select jsonb_agg(
              jsonb_build_object(
                'customer_id', c.customer_id,
                'customer_code', c.customer_code,
                'customer_name', c.customer_name
              ) order by lower(c.customer_name), c.customer_code
            )
            from public.customers c
            where c.active = true
              and c.deleted_at is null
          ),
          '[]'::jsonb
        )
      else '[]'::jsonb
    end,
    'trolley_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id', tt.trolley_type_id,
            'trolley_type_code', tt.trolley_type_code,
            'trolley_type_name', tt.trolley_type_name,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'trolley_category', tt.trolley_category,
            'footprint_length_cm', tt.footprint_length_cm,
            'footprint_width_cm', tt.footprint_width_cm,
            'footprint_area_m2', case
              when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
                then round((tt.footprint_length_cm * tt.footprint_width_cm / 10000.0)::numeric, 3)
              else null
            end,
            'tare_weight_kg', tt.tare_weight_kg,
            'allowed_in_customer_schedule', tt.allowed_in_customer_schedule
          ) order by tt.sort_order, tt.trolley_type_code
        )
        from public.trolley_types tt
        where tt.active = true
          and tt.deleted_at is null
      ),
      '[]'::jsonb
    )
  );
end;
$function$;

-- get_trolley_type_master()
CREATE OR REPLACE FUNCTION public.get_trolley_type_master()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_items jsonb := '[]'::jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'trolley_type_id', tt.trolley_type_id,
      'trolley_type_code', tt.trolley_type_code,
      'trolley_type_name', tt.trolley_type_name,
      'display_code', coalesce(tt.display_code, tt.trolley_type_code),
      'trolley_category', tt.trolley_category,
      'allowed_in_customer_schedule', tt.allowed_in_customer_schedule,
      'sort_order', tt.sort_order,
      'active', tt.active,
      'footprint_length_cm', tt.footprint_length_cm,
      'footprint_width_cm', tt.footprint_width_cm,
      'footprint_area_m2', case
        when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
          then round((tt.footprint_length_cm * tt.footprint_width_cm / 10000.0)::numeric, 3)
        else null
      end,
      'tare_weight_kg', tt.tare_weight_kg,
      'notes', nullif(coalesce(tt.metadata->>'trolley_type_notes',''),''),
      'physical_trolley_count', coalesce(usage.physical_trolley_count,0),
      'active_physical_trolley_count', coalesce(usage.active_physical_trolley_count,0),
      'schedule_requirement_count', coalesce(req.schedule_requirement_count,0),
      'active_schedule_requirement_count', coalesce(req.active_schedule_requirement_count,0),
      'created_at', tt.created_at,
      'updated_at', tt.updated_at
    )
    order by tt.sort_order, coalesce(tt.display_code,tt.trolley_type_code), tt.trolley_type_code
  ), '[]'::jsonb)
  into v_items
  from public.trolley_types tt
  left join lateral (
    select
      count(*)::integer as physical_trolley_count,
      count(*) filter(
        where t.active=true and t.deleted_at is null and t.status<>'RETIRED'
      )::integer as active_physical_trolley_count
    from public.trolleys t
    where t.trolley_type_id=tt.trolley_type_id
      and t.deleted_at is null
  ) usage on true
  left join lateral (
    select
      count(*)::integer as schedule_requirement_count,
      count(*) filter(where r.active=true)::integer as active_schedule_requirement_count
    from public.customer_schedule_trolley_requirements r
    where r.trolley_type_id=tt.trolley_type_id
  ) req on true
  where tt.deleted_at is null;

  return jsonb_build_object(
    'items', v_items,
    'can_manage', public.account_module_allowed(array['TROLLEYS'],'MANAGE',array['ADMIN','MANAGER']),
    'schedule_type_governance', 'NEW_TYPES_NOT_ALLOWED_BY_DEFAULT',
    'technical_code_contract', 'IMMUTABLE_AFTER_CREATE',
    'source', 'TROLLEY_TYPE_MASTER'
  );
end;
$function$;

-- production_roster_action_allowed(p_action text)
CREATE OR REPLACE FUNCTION public.production_roster_action_allowed(p_action text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v_uses_explicit_permissions boolean;
begin
  if auth.uid() is null then return false; end if;
  v_uses_explicit_permissions := public.account_uses_module_permissions();
  if v_uses_explicit_permissions then
    return public.has_account_permission('PRODUCTION_ROSTER',p_action,'PRODUCTION');
  end if;
  if upper(trim(p_action))='VIEW' then
    return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER','SUPERVISOR','AUDITOR']);
  end if;
  if upper(trim(p_action)) in ('CREATE','EDIT','APPROVE') then
    return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER','SUPERVISOR']);
  end if;
  return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER']);
end;
$function$;

-- publish_customer_schedule(p_schedule_version_id uuid, p_change_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.publish_customer_schedule(p_schedule_version_id uuid, p_change_reason text, p_source_application text DEFAULT 'CUSTOMER_SCHEDULE_MANAGEMENT'::text)
 RETURNS customer_schedule_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_published public.customer_schedule_versions%rowtype;
  v_previous record;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for schedule publication.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A publication reason is required.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception 'Schedule version not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception 'Only a DRAFT schedule revision can be published.';
  end if;

  if not exists (
    select 1
    from public.customers
    where customer_id = v_version.customer_id
      and active = true
      and deleted_at is null
  ) then
    raise exception 'The customer is inactive or does not exist.';
  end if;

  if not exists (
    select 1
    from public.customer_schedule_days
    where schedule_version_id = p_schedule_version_id
      and active = true
  ) then
    raise exception 'The schedule must contain at least one active production day.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and not exists (
        select 1
        from public.customer_schedule_products p
        where p.schedule_day_id = d.schedule_day_id
          and p.active = true
      )
  ) then
    raise exception 'Every active production day must contain at least one active product.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    left join public.customer_product_services s
      on s.customer_id = v_version.customer_id
     and s.product_type_id = p.product_type_id
     and s.active = true
     and s.deleted_at is null
     and s.effective_from <= v_version.effective_from
     and (
       s.effective_until is null
       or s.effective_until >= v_version.effective_from
     )
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and s.customer_product_service_id is null
  ) then
    raise exception 'The schedule contains a product that is not enabled for this customer.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and (not pt.active or pt.deleted_at is not null)
  ) then
    raise exception 'The schedule contains an inactive product type.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_product_variants spv
    join public.customer_schedule_products p
      on p.schedule_product_id = spv.schedule_product_id
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_variants pv
      on pv.product_variant_id = spv.product_variant_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and (not pv.active or pv.deleted_at is not null)
  ) then
    raise exception 'The schedule contains an inactive product variant.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_days d
    join public.distribution_routes r
      on r.route_id = d.default_route_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and (
        not r.active
        or r.deleted_at is not null
        or not r.allow_as_default
      )
  ) then
    raise exception 'The schedule contains an inactive route or a route that cannot be used as a default route.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    left join public.trolley_types tt
      on tt.trolley_type_id = req.trolley_type_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and (
        tt.trolley_type_id is null
        or not tt.active
        or not tt.allowed_in_customer_schedule
        or tt.deleted_at is not null
      )
  ) then
    raise exception 'The schedule contains an inactive or missing trolley type.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and not exists (
        select 1
        from public.customer_schedule_trolley_requirement_products map
        where map.schedule_trolley_requirement_id =
          req.schedule_trolley_requirement_id
      )
  ) then
    raise exception 'Every trolley requirement must serve at least one scheduled product.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and not exists (
        select 1
        from public.customer_schedule_trolley_requirement_products map
        where map.schedule_trolley_requirement_id =
          req.schedule_trolley_requirement_id
          and map.schedule_product_id = req.owner_schedule_product_id
      )
  ) then
    raise exception 'The trolley owner product must also be included in the products served by that trolley.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions existing
    where existing.customer_id = v_version.customer_id
      and existing.status = 'PUBLISHED'
      and existing.effective_from >= v_version.effective_from
      and existing.schedule_version_id is distinct from v_version.based_on_version_id
      and daterange(
        existing.effective_from,
        coalesce(existing.effective_until, 'infinity'::date),
        '[]'
      ) && daterange(
        v_version.effective_from,
        coalesce(v_version.effective_until, 'infinity'::date),
        '[]'
      )
  ) then
    raise exception 'A future published schedule already overlaps this proposed period. Cancel or revise that future schedule first.';
  end if;

  for v_previous in
    select *
    from public.customer_schedule_versions existing
    where existing.customer_id = v_version.customer_id
      and existing.status = 'PUBLISHED'
      and daterange(
        existing.effective_from,
        coalesce(existing.effective_until, 'infinity'::date),
        '[]'
      ) && daterange(
        v_version.effective_from,
        coalesce(v_version.effective_until, 'infinity'::date),
        '[]'
      )
    for update
  loop
    update public.customer_schedule_versions
    set
      status = 'SUPERSEDED',
      effective_until = case
        when v_previous.effective_from < v_version.effective_from
          then least(
            coalesce(v_previous.effective_until, v_version.effective_from - 1),
            v_version.effective_from - 1
          )
        else v_previous.effective_until
      end,
      superseded_at = now(),
      superseded_by = auth.uid(),
      updated_by = auth.uid()
    where schedule_version_id = v_previous.schedule_version_id;
  end loop;

  update public.customer_schedule_versions
  set
    status = 'PUBLISHED',
    change_reason = trim(p_change_reason),
    published_at = now(),
    published_by = auth.uid(),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id
  returning * into v_published;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'PUBLISH_CUSTOMER_SCHEDULE',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    to_jsonb(v_version),
    to_jsonb(v_published),
    trim(p_change_reason),
    p_source_application
  );

  return v_published;
end;
$function$;

-- reactivate_customer(p_customer_id uuid, p_product_codes text[], p_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.reactivate_customer(p_customer_id uuid, p_product_codes text[], p_reason text, p_source_application text DEFAULT 'CUSTOMER_MANAGEMENT'::text)
 RETURNS customers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'MANAGE',array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for customer reactivation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A reactivation reason is required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one product service is required to reactivate a customer.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if v_old.active then
    raise exception 'Customer is already active.';
  end if;

  update public.customers
  set
    active = true,
    deactivated_at = null,
    deactivated_by = null,
    deactivation_reason = null,
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = p_customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        p_customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
  end loop;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'REACTIVATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_reason),
    p_source_application
  );

  return v_customer;
end;
$function$;

-- refresh_customer_kg_estimates_v1()
CREATE OR REPLACE FUNCTION public.refresh_customer_kg_estimates_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not public.current_account_is_enabled()
     or not public.account_module_allowed(array['CUSTOMERS'],'MANAGE',array['ADMIN','MANAGER']) then
    raise exception using errcode='42501', message='Your active role cannot refresh customer KG estimates.';
  end if;
  return public.refresh_customer_kg_estimate_snapshot();
end;
$function$;

-- require_any_customer_read_role(p_role_codes text[])
CREATE OR REPLACE FUNCTION public.require_any_customer_read_role(p_role_codes text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'An authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'] || public.legacy_role_modules(p_role_codes),'VIEW',p_role_codes) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to read this customer information.';
  end if;
end;
$function$;

-- require_any_trolley_role(p_role_codes text[])
CREATE OR REPLACE FUNCTION public.require_any_trolley_role(p_role_codes text[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not public.account_module_allowed(array['TROLLEYS'] || public.legacy_role_modules(p_role_codes),public.trolley_action_for_roles(p_role_codes),p_role_codes) then
    raise exception using
      errcode = '42501',
      message = 'Permission denied for this trolley operation.';
  end if;
end;
$function$;

-- require_customer_schedule_edit_role()
CREATE OR REPLACE FUNCTION public.require_customer_schedule_edit_role()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using
      errcode = '42501',
      message = 'An active authenticated account is required.';
  end if;

  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to manage Customer Schedules.';
  end if;
end;
$function$;

-- require_customer_schedule_history_role()
CREATE OR REPLACE FUNCTION public.require_customer_schedule_history_role()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Customer Schedule history.';
  end if;
end;
$function$;

-- require_distribution_master_access()
CREATE OR REPLACE FUNCTION public.require_distribution_master_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_distribution_read_access();
  if not public.account_module_allowed(array['DISTRIBUTION'],'MANAGE',array['ADMIN','MANAGER','SUPERVISOR']) then
    raise exception using errcode = '42501', message = 'Your active role cannot manage Distribution master data.';
  end if;
end;
$function$;

-- require_distribution_plan_access()
CREATE OR REPLACE FUNCTION public.require_distribution_plan_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_distribution_read_access();
  if not public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Your active role cannot plan Distribution routes.';
  end if;
end;
$function$;

-- require_distribution_read_access()
CREATE OR REPLACE FUNCTION public.require_distribution_read_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active authenticated account is required.';
  end if;
  if not public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']) then
    raise exception using errcode = '42501', message = 'Your active role does not allow access to Distribution.';
  end if;
end;
$function$;

-- require_distribution_roster_manage_access()
CREATE OR REPLACE FUNCTION public.require_distribution_roster_manage_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_distribution_roster_read_access();
  if not public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR']) then
    raise exception 'You do not have permission to manage Distribution Roster.' using errcode='42501';
  end if;
end;
$function$;

-- require_distribution_roster_read_access()
CREATE OR REPLACE FUNCTION public.require_distribution_roster_read_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'An active authenticated staff account is required.' using errcode='42501';
  end if;
  if not public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR','AUDITOR']) then
    raise exception 'You do not have access to Distribution Roster.' using errcode='42501';
  end if;
end;
$function$;

-- require_finish_production_access()
CREATE OR REPLACE FUNCTION public.require_finish_production_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'An authenticated Finish account is required.';
  end if;

  if not public.current_account_is_enabled() then
    raise exception using errcode = '42501', message = 'An active Finish account or registered Finish computer is required.';
  end if;

  if not public.account_module_allowed(array['FINISH'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Your role cannot use Finish Production.';
  end if;
end;
$function$;

-- require_operational_report_submit_access(p_source_area_code text, p_product_code text)
CREATE OR REPLACE FUNCTION public.require_operational_report_submit_access(p_source_area_code text, p_product_code text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
    if not public.account_module_allowed(array['MOP','SORTING'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','MOP_OPERATOR','SORTING_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report MOP operational schedule data.';
    end if;
    return;
  end if;

  if v_area = 'FINISH' and v_product = 'CLOTHES' then
    if not public.account_module_allowed(array['FINISH'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
      raise exception using errcode = '42501', message = 'Your role cannot report Finish operational schedule data.';
    end if;
    return;
  end if;

  raise exception using errcode = '42501', message = 'The requested operational report area/product scope is not allowed.';
end;
$function$;

-- require_production_flow_abs_batch_write_access(p_production_flow_item_id uuid)
CREATE OR REPLACE FUNCTION public.require_production_flow_abs_batch_write_access(p_production_flow_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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

  if public.account_module_allowed(array['FINISH','MOP'],'APPROVE',array['ADMIN','MANAGER','SUPERVISOR']) then
    return;
  end if;

  if public.account_module_allowed(array['FINISH'],'EDIT',array['FINISH_OPERATOR']) and v_product_code='CLOTHES' then
    return;
  end if;

  if public.account_module_allowed(array['MOP'],'EDIT',array['MOP_OPERATOR']) and v_product_code='MOP' then
    return;
  end if;

  if public.account_module_allowed(array['SORTING'],'EDIT',array['SORTING_OPERATOR']) and v_product_code='MOP' then
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
$function$;

-- require_production_flow_batch_write_role()
CREATE OR REPLACE FUNCTION public.require_production_flow_batch_write_role()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null
     or not public.current_account_is_enabled()
     or not public.account_module_allowed(array['FINISH','MOP'],'EDIT',array[
       'ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow ABS production batch entry.';
  end if;
end;
$function$;

-- require_production_flow_read_role()
CREATE OR REPLACE FUNCTION public.require_production_flow_read_role()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null
     or not public.account_module_allowed(array['SORTING','FINISH','MOP','DISTRIBUTION','PRODUCTION_TRACKER'],'VIEW',array[
       'ADMIN','MANAGER','SUPERVISOR','AUDITOR',
       'SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR'
     ]) then
    raise exception using
      errcode = '42501',
      message = 'Your active role does not allow access to Production Flow.';
  end if;
end;
$function$;

-- require_production_roster_read_role()
CREATE OR REPLACE FUNCTION public.require_production_roster_read_role()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if not public.account_module_allowed(array['PRODUCTION_ROSTER'],'VIEW',array['ADMIN', 'MANAGER', 'ROSTER_MANAGER', 'SUPERVISOR', 'AUDITOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to view the Production Roster.';
  end if;
end;
$function$;

-- require_sorting_operational_access()
CREATE OR REPLACE FUNCTION public.require_sorting_operational_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if public.account_module_allowed(array['SORTING'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']) then
    return;
  end if;

  if current_setting('eliscaretex.mop_operational_scope',true)='on'
     and public.account_module_allowed(array['MOP'],'EDIT',array['MOP_OPERATOR']) then
    return;
  end if;

  raise exception using
    errcode='42501',
    message='Your active role does not allow access to Sorting Area.';
end;
$function$;

-- require_trolley_type_master_write_access()
CREATE OR REPLACE FUNCTION public.require_trolley_type_master_write_access()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  if auth.uid() is null
     or not public.current_account_is_enabled()
     or not public.account_module_allowed(array['TROLLEYS'],'MANAGE',array['ADMIN','MANAGER']) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow Trolley Type Master changes.';
  end if;
end;
$function$;

-- staff_master_action_allowed(p_action text)
CREATE OR REPLACE FUNCTION public.staff_master_action_allowed(p_action text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_uses_explicit_permissions boolean;
begin
  if auth.uid() is null then
    return false;
  end if;

  v_uses_explicit_permissions := public.account_uses_module_permissions();

  if v_uses_explicit_permissions then
    return public.has_account_permission('STAFF_MASTER', p_action, 'PRODUCTION');
  end if;

  -- Temporary compatibility for accounts that have not yet been migrated to
  -- explicit grants. Once migrated, their grant is always authoritative.
  if upper(trim(p_action)) = 'VIEW' then
    return public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER', 'SUPERVISOR', 'AUDITOR']);
  end if;
  return public.has_any_role(array['ADMIN', 'MANAGER']);
end;
$function$;

-- update_customer(p_customer_id uuid, p_expected_row_version integer, p_customer_code text, p_customer_name text, p_eircode text, p_distribution_estimated_kg numeric, p_distribution_stop_count integer, p_notes text, p_operational_alert text, p_product_codes text[], p_change_reason text, p_source_application text)
CREATE OR REPLACE FUNCTION public.update_customer(p_customer_id uuid, p_expected_row_version integer, p_customer_code text, p_customer_name text, p_eircode text, p_distribution_estimated_kg numeric, p_distribution_stop_count integer, p_notes text, p_operational_alert text, p_product_codes text[], p_change_reason text, p_source_application text DEFAULT 'CUSTOMER_MANAGEMENT'::text)
 RETURNS customers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for customer update.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A change reason is required.';
  end if;

  if nullif(trim(p_customer_code), '') is null
     or nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer code and customer name are required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one customer product service is required for an active customer.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if not v_old.active then
    raise exception 'Inactive customers must be reactivated before normal editing.';
  end if;

  if v_old.row_version <> p_expected_row_version then
    raise exception 'This customer was changed by another user. Reload it before saving.';
  end if;

  update public.customers
  set
    customer_code = upper(trim(p_customer_code)),
    customer_name = trim(p_customer_name),
    eircode = nullif(trim(p_eircode), ''),
    distribution_estimated_kg = p_distribution_estimated_kg,
    distribution_stop_count = p_distribution_stop_count,
    notes = nullif(trim(p_notes), ''),
    operational_alert = nullif(trim(p_operational_alert), ''),
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  update public.customer_product_services cps
  set
    active = false,
    effective_until = public.current_business_date(),
    updated_by = auth.uid()
  where cps.customer_id = p_customer_id
    and cps.active = true
    and cps.deleted_at is null
    and not exists (
      select 1
      from unnest(p_product_codes) as requested(product_code)
      join public.product_types pt
        on pt.product_code = upper(trim(requested.product_code))
      where pt.product_type_id = cps.product_type_id
    );

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = p_customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        p_customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
  end loop;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'UPDATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_change_reason),
    p_source_application
  );

  return v_customer;
end;
$function$;

-- update_sorting_mop_type_master(p_product_variant_id uuid, p_display_name text, p_unit_weight_grams numeric, p_notes text, p_image_url text, p_remove_image boolean)
CREATE OR REPLACE FUNCTION public.update_sorting_mop_type_master(p_product_variant_id uuid, p_display_name text, p_unit_weight_grams numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_image_url text DEFAULT NULL::text, p_remove_image boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_actor_staff_id uuid;
  v_variant public.product_variants%rowtype;
  v_before jsonb;
  v_metadata jsonb;
  v_image_url text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication is required.';
  end if;

  v_actor_staff_id := public.current_staff_id();
  if not public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']) then
    raise exception using errcode = '42501', message = 'Only ADMIN or MANAGER may manage MOP Types.';
  end if;

  if p_product_variant_id is null then
    raise exception using errcode = '22023', message = 'MOP type is required.';
  end if;
  if nullif(trim(p_display_name), '') is null then
    raise exception using errcode = '22023', message = 'MOP type name is required.';
  end if;
  if p_unit_weight_grams is not null and p_unit_weight_grams <= 0 then
    raise exception using errcode = '22023', message = 'Unit weight must be greater than zero when provided.';
  end if;
  if length(coalesce(p_display_name, '')) > 160 then
    raise exception using errcode = '22023', message = 'MOP type name is too long.';
  end if;
  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'MOP type notes are too long.';
  end if;
  if length(coalesce(p_image_url, '')) > 2000 then
    raise exception using errcode = '22023', message = 'MOP type image URL is too long.';
  end if;

  select pv.*
  into v_variant
  from public.product_variants pv
  join public.product_types pt
    on pt.product_type_id = pv.product_type_id
   and pt.product_code = 'MOP'
   and pt.deleted_at is null
  where pv.product_variant_id = p_product_variant_id
    and pv.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'MOP type not found.';
  end if;

  v_before := to_jsonb(v_variant);
  v_metadata := coalesce(v_variant.metadata, '{}'::jsonb) - 'weight_per_unit_grams';

  if p_unit_weight_grams is null then
    v_metadata := v_metadata - 'unit_weight_grams';
  else
    v_metadata := jsonb_set(v_metadata, '{unit_weight_grams}', to_jsonb(round(p_unit_weight_grams, 3)), true);
  end if;

  if nullif(trim(coalesce(p_notes, '')), '') is null then
    v_metadata := v_metadata - 'notes';
  else
    v_metadata := jsonb_set(v_metadata, '{notes}', to_jsonb(trim(p_notes)), true);
  end if;

  if p_remove_image then
    v_metadata := v_metadata - 'image_url' - 'photo_url';
    v_image_url := null;
  elsif nullif(trim(coalesce(p_image_url, '')), '') is not null then
    v_image_url := trim(p_image_url);
    v_metadata := v_metadata - 'photo_url';
    v_metadata := jsonb_set(v_metadata, '{image_url}', to_jsonb(v_image_url), true);
  else
    v_image_url := nullif(coalesce(v_variant.metadata->>'image_url', v_variant.metadata->>'photo_url', ''), '');
  end if;

  update public.product_variants
  set display_name = trim(p_display_name),
      metadata = v_metadata,
      updated_at = now(),
      updated_by = auth.uid()
  where product_variant_id = p_product_variant_id
  returning * into v_variant;

  insert into public.audit_log(
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'MOP_TYPE_MASTER_UPDATED', 'product_variants',
    v_variant.product_variant_id::text, v_before, to_jsonb(v_variant),
    'MOP type master maintained from Sorting MOP Types', 'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'product_variant_id', v_variant.product_variant_id,
    'variant_code', v_variant.variant_code,
    'display_name', v_variant.display_name,
    'unit_weight_grams', case
      when coalesce(v_variant.metadata->>'unit_weight_grams','') ~ '^[0-9]+([.][0-9]+)?$'
        then (v_variant.metadata->>'unit_weight_grams')::numeric
      else null end,
    'image_url', nullif(coalesce(v_variant.metadata->>'image_url',''),''),
    'notes', nullif(coalesce(v_variant.metadata->>'notes',''),''),
    'message', 'MOP type updated.'
  );
end;
$function$;

-- update_sorting_mop_type_master_v2(p_product_variant_id uuid, p_display_name text, p_category text, p_unit_weight_grams numeric, p_notes text, p_image_url text, p_remove_image boolean, p_sort_order integer)
CREATE OR REPLACE FUNCTION public.update_sorting_mop_type_master_v2(p_product_variant_id uuid, p_display_name text, p_category text DEFAULT NULL::text, p_unit_weight_grams numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_image_url text DEFAULT NULL::text, p_remove_image boolean DEFAULT false, p_sort_order integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_actor_staff_id uuid;
  v_variant public.product_variants%rowtype;
  v_before jsonb;
  v_metadata jsonb;
  v_category text;
  v_notes text;
  v_image_url text;
  v_sort_order integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication is required.';
  end if;

  v_actor_staff_id := public.current_staff_id();
  if not public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']) then
    raise exception using errcode = '42501', message = 'Only ADMIN or MANAGER may manage MOP Types.';
  end if;

  if p_product_variant_id is null then
    raise exception using errcode = '22023', message = 'MOP type is required.';
  end if;
  if nullif(trim(coalesce(p_display_name,'')), '') is null then
    raise exception using errcode = '22023', message = 'MOP type name is required.';
  end if;
  if length(trim(p_display_name)) > 160 then
    raise exception using errcode = '22023', message = 'MOP type name is too long.';
  end if;

  v_category := nullif(trim(coalesce(p_category,'')), '');
  if length(coalesce(v_category,'')) > 120 then
    raise exception using errcode = '22023', message = 'MOP type category is too long.';
  end if;

  if p_unit_weight_grams is not null and p_unit_weight_grams <= 0 then
    raise exception using errcode = '22023', message = 'Unit weight must be greater than zero when provided.';
  end if;

  v_notes := nullif(trim(coalesce(p_notes,'')), '');
  if length(coalesce(v_notes,'')) > 1000 then
    raise exception using errcode = '22023', message = 'MOP type notes are too long.';
  end if;

  v_image_url := nullif(trim(coalesce(p_image_url,'')), '');
  if length(coalesce(v_image_url,'')) > 2000 then
    raise exception using errcode = '22023', message = 'MOP type image URL is too long.';
  end if;
  if v_image_url is not null
     and position('/storage/v1/object/public/mop-type-photos/' in v_image_url) = 0 then
    raise exception using errcode = '22023', message = 'MOP type image must come from the mop-type-photos Storage bucket.';
  end if;

  if p_sort_order is not null and (p_sort_order < 0 or p_sort_order > 100000) then
    raise exception using errcode = '22023', message = 'Display order must be between 0 and 100000.';
  end if;

  select pv.*
  into v_variant
  from public.product_variants pv
  join public.product_types pt
    on pt.product_type_id = pv.product_type_id
   and pt.product_code = 'MOP'
   and pt.deleted_at is null
  where pv.product_variant_id = p_product_variant_id
    and pv.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'MOP type not found.';
  end if;

  v_before := to_jsonb(v_variant);
  v_metadata := coalesce(v_variant.metadata, '{}'::jsonb)
    - 'weight_per_unit_grams'
    - 'type';

  if p_unit_weight_grams is null then
    v_metadata := v_metadata - 'unit_weight_grams' - 'unit_weight_source';
  else
    v_metadata := jsonb_set(v_metadata, '{unit_weight_grams}', to_jsonb(round(p_unit_weight_grams,3)), true);
    v_metadata := jsonb_set(v_metadata, '{unit_weight_source}', to_jsonb('MOP_TYPE_MASTER_MANUAL'::text), true);
    v_metadata := v_metadata - 'unit_weight_review_required';
  end if;

  if v_category is null then
    v_metadata := v_metadata - 'category';
  else
    v_metadata := jsonb_set(v_metadata, '{category}', to_jsonb(v_category), true);
  end if;

  if v_notes is null then
    v_metadata := v_metadata - 'notes';
  else
    v_metadata := jsonb_set(v_metadata, '{notes}', to_jsonb(v_notes), true);
  end if;

  if p_remove_image then
    v_metadata := v_metadata - 'image_url' - 'photo_url';
  elsif v_image_url is not null then
    v_metadata := v_metadata - 'photo_url';
    v_metadata := jsonb_set(v_metadata, '{image_url}', to_jsonb(v_image_url), true);
  end if;

  v_sort_order := coalesce(p_sort_order, v_variant.sort_order);

  update public.product_variants
  set display_name = trim(p_display_name),
      sort_order = v_sort_order,
      metadata = v_metadata,
      updated_at = now(),
      updated_by = auth.uid()
  where product_variant_id = p_product_variant_id
  returning * into v_variant;

  insert into public.audit_log(
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'MOP_TYPE_MASTER_UPDATED', 'product_variants',
    v_variant.product_variant_id::text, v_before, to_jsonb(v_variant),
    'MOP type master maintained from Sorting MOP Types Management', 'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'product_variant_id', v_variant.product_variant_id,
    'variant_code', v_variant.variant_code,
    'display_name', v_variant.display_name,
    'active', v_variant.active,
    'sort_order', v_variant.sort_order,
    'category', nullif(coalesce(v_variant.metadata->>'category',''),''),
    'unit_weight_grams', case
      when coalesce(v_variant.metadata->>'unit_weight_grams','') ~ '^[0-9]+([.][0-9]+)?$'
        then (v_variant.metadata->>'unit_weight_grams')::numeric
      else null end,
    'image_url', nullif(coalesce(v_variant.metadata->>'image_url',''),''),
    'notes', nullif(coalesce(v_variant.metadata->>'notes',''),''),
    'message', 'MOP type updated.'
  );
end;
$function$;

-- 5. Direct-read RLS policies -------------------------------------------

alter policy read_active_customers_or_customer_management on public.customers
  using ((deleted_at is null) and ((active = true) or public.account_module_allowed(
    array['CUSTOMERS','DISTRIBUTION'], 'VIEW',
    array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR'])));

alter policy staff_read_own_profile_or_management on public.staff_members
  using ((auth_user_id = (select auth.uid())) or (select public.account_module_allowed(
    array['STAFF_MASTER','PRODUCTION_ROSTER'], 'VIEW',
    array['ADMIN','MANAGER','SUPERVISOR','ROSTER_MANAGER','AUDITOR'])));

alter policy staff_read_own_roles_or_management on public.staff_roles
  using ((staff_id = public.current_staff_id()) or public.account_module_allowed(
    array['STAFF_MASTER','PRODUCTION_ROSTER'], 'VIEW',
    array['ADMIN','MANAGER','SUPERVISOR','ROSTER_MANAGER','AUDITOR']));

commit;
