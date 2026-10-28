-- Customer Master: a written reason on every edit and a visible change history
-- (owner request 2026-10-28).
--
-- Owner: "I changed a customer's name, nothing was asked of me and no history was created."
-- update_customer already wrote one audit_log row per edit (who, when, old_data,
-- new_data, reason), but:
--   * the page filled the reason in by itself ("Updated Customer Master for X: ..."),
--     so nobody was ever asked why;
--   * services changed in the same edit were not in old_data/new_data;
--   * nothing on the page showed the audit_log rows.
--
-- This migration:
--   1. Replaces update_customer: the reason must be typed by the person (at least 10
--      characters, and not the text the old page generated), an edit that changes
--      nothing is refused, and the services before and after are stored in the
--      audit row as product_services. Everything else is unchanged.
--   2. Adds get_customer_master_change_history(uuid): every audit_log row of one
--      customer (Customer Master edits, create, deactivate, reactivate, imports and
--      legacy sync), newest first, with the person's name, the reason and the fields
--      that changed with their old and new values. Read-only, CUSTOMERS:VIEW.
-- No table, column or row changes. Existing audit rows are shown as they are.

create or replace function public.update_customer(
  p_customer_id uuid,
  p_expected_row_version integer,
  p_customer_code text,
  p_customer_name text,
  p_eircode text,
  p_distribution_estimated_kg numeric,
  p_distribution_stop_count integer,
  p_notes text,
  p_operational_alert text,
  p_product_codes text[],
  p_change_reason text,
  p_source_application text default 'CUSTOMER_MANAGEMENT'::text
)
returns public.customers
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
  v_reason text := nullif(trim(p_change_reason), '');
  v_old_services text[];
  v_new_services text[];
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'EDIT',array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
    raise exception 'Permission denied for customer update.';
  end if;

  if v_reason is null
     or length(v_reason) < 10
     or v_reason like 'Updated Customer Master for %' then
    raise exception using errcode = '22023',
      message = 'Write the reason for this change (at least 10 characters).';
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

  select coalesce(array_agg(distinct pt.product_code order by pt.product_code), array[]::text[])
  into v_old_services
  from public.customer_product_services cps
  join public.product_types pt on pt.product_type_id = cps.product_type_id
  where cps.customer_id = p_customer_id
    and cps.active = true
    and cps.effective_until is null
    and cps.deleted_at is null;

  select coalesce(array_agg(distinct upper(trim(c)) order by upper(trim(c))), array[]::text[])
  into v_new_services
  from unnest(p_product_codes) c;

  if v_old.customer_code is not distinct from upper(trim(p_customer_code))
     and v_old.customer_name is not distinct from trim(p_customer_name)
     and v_old.eircode is not distinct from nullif(trim(p_eircode), '')
     and v_old.distribution_estimated_kg is not distinct from p_distribution_estimated_kg
     and v_old.distribution_stop_count is not distinct from p_distribution_stop_count
     and v_old.notes is not distinct from nullif(trim(p_notes), '')
     and v_old.operational_alert is not distinct from nullif(trim(p_operational_alert), '')
     and v_old_services = v_new_services then
    raise exception using errcode = '22023', message = 'No customer changes to save.';
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
    to_jsonb(v_old) || jsonb_build_object('product_services', to_jsonb(v_old_services)),
    to_jsonb(v_customer) || jsonb_build_object('product_services', to_jsonb(v_new_services)),
    v_reason,
    p_source_application
  );

  return v_customer;
end;
$$;

revoke all on function public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text) from public, anon;
grant execute on function public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text) to authenticated;

-- Every recorded change of one customer, newest first. Names are resolved the same
-- way as the roster history (account display name, Staff Master name, login email).
create or replace function public.get_customer_master_change_history(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
begin
  if not public.account_module_allowed(array['CUSTOMERS'],'VIEW',array['ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Permission denied for customer history.';
  end if;

  select * into v_customer
  from public.customers
  where customer_id = p_customer_id and deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Customer not found.';
  end if;

  return jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_name', v_customer.customer_name,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'audit_id', a.audit_id,
        'occurred_at', a.occurred_at,
        'action', a.action,
        'actor_name', coalesce(
          public.production_roster_actor_name(a.actor_auth_user_id, a.actor_staff_id),
          case
            when a.source_application like 'LEGACY_SYNC%' then 'Legacy sync (Apps Script)'
            when a.source_application like 'APPS_SCRIPT%' then 'Apps Script import'
            when a.source_application like 'migration%' then 'System migration'
          end
        ),
        'reason', a.reason,
        'source_application', a.source_application,
        'changes', coalesce((
          select jsonb_agg(jsonb_build_object(
            'field', f.field_key,
            'label', f.label,
            'before', a.old_data -> f.field_key,
            'after', a.new_data -> f.field_key
          ) order by f.sort_order)
          from (values
            ('customer_code', 'Customer code', 1),
            ('customer_name', 'Customer name', 2),
            ('eircode', 'Eircode', 3),
            ('distribution_estimated_kg', 'Estimated KG', 4),
            ('distribution_stop_count', 'Stops', 5),
            ('notes', 'General notes', 6),
            ('operational_alert', 'Operational alert', 7),
            ('product_services', 'Services', 8),
            ('active', 'Active', 9),
            ('deactivation_reason', 'Deactivation reason', 10)
          ) as f(field_key, label, sort_order)
          where a.old_data ? f.field_key
            and a.new_data ? f.field_key
            and a.old_data -> f.field_key is distinct from a.new_data -> f.field_key
        ), '[]'::jsonb)
      ) order by a.occurred_at desc, a.audit_id)
      from (
        select *
        from public.audit_log l
        where l.entity_table = 'customers'
          and l.entity_id = p_customer_id::text
        order by l.occurred_at desc
        limit 200
      ) a
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_customer_master_change_history(uuid) from public, anon;
grant execute on function public.get_customer_master_change_history(uuid) to authenticated;
