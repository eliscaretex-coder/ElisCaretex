-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300008_customer_master_management_api.sql
-- Purpose:
--   Add small permission-controlled helper RPCs used by the Customer
--   Master list and form. The transactional create, update, deactivate
--   and reactivate functions already exist from migration 002.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety checks
-- ---------------------------------------------------------------------

do $$
begin
  if to_regclass('public.customers') is null
     or to_regclass('public.customer_product_services') is null
     or to_regclass('public.customer_schedule_versions') is null then
    raise exception 'Required Customer V2 tables are missing.';
  end if;

  if to_regprocedure(
    'public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text)'
  ) is null
     or to_regprocedure(
       'public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)'
     ) is null
     or to_regprocedure(
       'public.deactivate_customer(uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.reactivate_customer(uuid,text[],text,text)'
     ) is null then
    raise exception 'Required customer management functions from migration 002 are missing.';
  end if;

  if to_regprocedure('public.get_customer_read_capabilities()') is null
     or to_regprocedure(
       'public.get_customer_directory(text,text,text,date,integer,integer)'
     ) is null then
    raise exception 'Customer Read API migration 007 must be applied first.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Internal technical customer-code generator
--
-- Customer users do not need to invent a database identifier. The result
-- is readable enough for support while remaining unique.
-- ---------------------------------------------------------------------

create or replace function public.generate_customer_code(
  p_customer_name text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base text;
  v_code text;
  v_attempt integer := 0;
begin
  v_base := upper(
    regexp_replace(
      coalesce(nullif(trim(p_customer_name), ''), 'CUSTOMER'),
      '[^A-Za-z0-9]+',
      '',
      'g'
    )
  );

  if v_base = '' then
    v_base := 'CUSTOMER';
  end if;

  v_base := left(v_base, 10);

  loop
    v_attempt := v_attempt + 1;

    v_code := concat(
      'CUS-',
      v_base,
      '-',
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))
    );

    exit when not exists (
      select 1
      from public.customers c
      where c.customer_code = v_code
    );

    if v_attempt >= 20 then
      raise exception 'Unable to generate a unique customer code.';
    end if;
  end loop;

  return v_code;
end;
$$;

revoke all on function public.generate_customer_code(text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Customer Master reference data
-- ---------------------------------------------------------------------

create or replace function public.get_customer_master_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  );

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_edit_customers', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER']
    ),
    'can_deactivate_customers', public.has_any_role(
      array['ADMIN', 'MANAGER']
    ),
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
$$;

-- ---------------------------------------------------------------------
-- Complete Customer Master record
--
-- Distribution-sensitive master fields are returned only to roles that can
-- maintain customers. Operators continue to use the area-specific read APIs.
-- ---------------------------------------------------------------------

create or replace function public.get_customer_master_record(
  p_customer_id uuid,
  p_effective_date date default public.current_business_date()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
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
$$;

-- ---------------------------------------------------------------------
-- User-friendly create wrapper
-- ---------------------------------------------------------------------

create or replace function public.create_customer_master(
  p_customer_name text,
  p_eircode text default null,
  p_distribution_estimated_kg numeric default null,
  p_distribution_stop_count integer default null,
  p_notes text default null,
  p_operational_alert text default null,
  p_product_codes text[] default array[]::text[],
  p_change_reason text default null,
  p_source_application text default 'CUSTOMER_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
  v_customer_code text;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
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
$$;

revoke all on function public.get_customer_master_reference_data()
  from public, anon;
revoke all on function public.get_customer_master_record(uuid, date)
  from public, anon;
revoke all on function public.create_customer_master(
  text, text, numeric, integer, text, text, text[], text, text
) from public, anon;

grant execute on function public.get_customer_master_reference_data()
  to authenticated;
grant execute on function public.get_customer_master_record(uuid, date)
  to authenticated;
grant execute on function public.create_customer_master(
  text, text, numeric, integer, text, text, text[], text, text
) to authenticated;

commit;
