-- =====================================================================
-- ElisCaretex V2
-- Capture the live definitions of functions that drifted from the repository
--
-- The functions below were changed in the live database outside the
-- committed migrations (SQL Editor, live-only migrations such as
-- distribution_roster_driver_matrix_corrected_20260817,
-- finish_reviewed_historical_import, and runtime rewrites done by
-- 202609090027/28, 202609100001/02 and 202610230001), or exist only in the
-- live database. Each definition here is pg_get_functiondef() output taken
-- from ElisCaretex-dev on 2026-10-23, unchanged, so the repository again
-- matches the database. Replaying the repository now produces the live
-- behaviour, including record_finish_rewash_v1 (202609160003 referenced the
-- non-existent table finish_workstations).
--
-- Applying this file to ElisCaretex-dev changes nothing: every body is
-- identical to the live one and CREATE OR REPLACE keeps existing grants.
-- The orphan Distribution Roster RPCs stay revoked (202610230004); the
-- revoke is repeated below so a fresh replay ends in the same state.
--
-- Note: finish_enforce_new_entry_current_shift carries the temporary
-- Apps Script import exception (2026-09-26 to 2026-10-23, postgres session
-- only). Remove it in a later migration once the import is reconciled.
-- =====================================================================

begin;

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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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

-- cancel_sorting_trolley_intake(p_sorting_trolley_intake_id uuid, p_reason text)
CREATE OR REPLACE FUNCTION public.cancel_sorting_trolley_intake(p_sorting_trolley_intake_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_intake public.sorting_trolley_intakes%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_actor_staff_id uuid := public.current_staff_id();
  v_flow_id uuid;
begin
  perform public.require_sorting_operational_access();
  if p_sorting_trolley_intake_id is null then raise exception using errcode='22023', message='Trolley intake record is required.'; end if;
  if v_reason is null then raise exception using errcode='22023', message='Removal reason is required.'; end if;
  select * into v_intake from public.sorting_trolley_intakes where sorting_trolley_intake_id=p_sorting_trolley_intake_id for update;
  if not found then raise exception using errcode='P0002', message='Trolley intake record was not found.'; end if;
  if coalesce(v_intake.record_status,'RECORDED')='CANCELLED' then raise exception using errcode='22023', message='Trolley intake is already cancelled.'; end if;
  v_before := to_jsonb(v_intake) || jsonb_build_object('products',coalesce((select jsonb_agg(to_jsonb(stip) order by stip.product_code) from public.sorting_trolley_intake_products stip where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id),'[]'::jsonb));
  update public.sorting_trolley_intakes set record_status='CANCELLED', cancellation_reason=v_reason, cancelled_at=now(), cancelled_by_auth_user_id=auth.uid(), revision_no=revision_no+1 where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id returning revision_no into v_revision;
  select to_jsonb(sti) into v_after from public.sorting_trolley_intakes sti where sti.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  insert into public.sorting_trolley_intake_revisions(sorting_trolley_intake_id,revision_no,action_type,reason,before_data,after_data,changed_by_auth_user_id,changed_by_staff_id) values(v_intake.sorting_trolley_intake_id,v_revision,'CANCELLED',v_reason,v_before,v_after,auth.uid(),v_actor_staff_id);
  for v_flow_id in select distinct production_flow_item_id from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id loop
    perform public.append_production_flow_event(v_flow_id,'TROLLEY_INTAKE_CANCELLED','INTAKE',20,'SORTING',v_intake.business_date,now(),v_intake.operator_staff_id,v_actor_staff_id,auth.uid(),'SORTING_V2','sorting_trolley_intake_revisions',v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,jsonb_build_object('reason',v_reason,'trolley_code',v_intake.trolley_code_snapshot,'customer_id',v_intake.customer_id));
    perform public.refresh_production_flow_wash_summary(v_flow_id);
  end loop;
  return jsonb_build_object('status','cancelled','revision_no',v_revision,'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id);
end; $function$;

-- correct_sorting_trolley_intake(p_sorting_trolley_intake_id uuid, p_customer_id uuid, p_scheduled_for_date date, p_product_codes text[], p_contents_status text, p_reason text)
CREATE OR REPLACE FUNCTION public.correct_sorting_trolley_intake(p_sorting_trolley_intake_id uuid, p_customer_id uuid, p_scheduled_for_date date, p_product_codes text[], p_contents_status text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_intake public.sorting_trolley_intakes%rowtype;
  v_customer public.customers%rowtype;
  v_business_date date;
  v_relation text;
  v_contents text := upper(trim(coalesce(p_contents_status,'')));
  v_products text[];
  v_current_products text[];
  v_product text;
  v_product_scope text;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_actor_staff_id uuid := public.current_staff_id();
  v_old_flow_ids uuid[];
  v_new_flow_id uuid;
  v_snapshot record;
  v_downstream_wash_count integer := 0;
begin
  perform public.require_sorting_operational_access();
  if p_sorting_trolley_intake_id is null then raise exception using errcode='22023', message='Trolley intake record is required.'; end if;
  if v_reason is null then raise exception using errcode='22023', message='Correction reason is required.'; end if;
  if v_contents not in ('CONTENTS','EMPTY') then raise exception using errcode='22023', message='Choose Laundry inside or Empty trolley.'; end if;

  select * into v_intake from public.sorting_trolley_intakes where sorting_trolley_intake_id=p_sorting_trolley_intake_id for update;
  if not found then raise exception using errcode='P0002', message='Trolley intake record was not found.'; end if;
  if coalesce(v_intake.record_status,'RECORDED')='CANCELLED' then raise exception using errcode='22023', message='Cancelled trolley intake cannot be edited.'; end if;

  v_business_date := v_intake.business_date;
  v_relation := public.sorting_schedule_relation_for_date(v_business_date,p_scheduled_for_date,true);

  select * into v_customer from public.customers where customer_id=p_customer_id and active=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Confirmed customer is not active.'; end if;

  select array_agg(distinct upper(trim(x)) order by upper(trim(x))) into v_products from unnest(coalesce(p_product_codes,array[]::text[])) x where upper(trim(x)) in ('CLOTHES','MOP');
  if coalesce(array_length(v_products,1),0)=0 or array_length(v_products,1)>2 then raise exception using errcode='22023', message='Choose Clothes, MOP or Both.'; end if;

  select array_agg(product_code order by product_code) into v_current_products from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  select coalesce(count(*),0) into v_downstream_wash_count from public.sorting_trolley_intake_products stip join public.sorting_wash_run_customers wrc on wrc.production_flow_item_id=stip.production_flow_item_id join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED' where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  if v_downstream_wash_count>0 and (v_contents is distinct from v_intake.contents_status or v_products is distinct from v_current_products) then
    raise exception using errcode='22023', message='This trolley has already been washed. Customer and Scheduled Date can be corrected, but product and contents must stay unchanged.';
  end if;

  v_before := to_jsonb(v_intake) || jsonb_build_object('products',coalesce((select jsonb_agg(to_jsonb(stip) order by stip.product_code) from public.sorting_trolley_intake_products stip where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id),'[]'::jsonb));
  select array_agg(distinct production_flow_item_id) into v_old_flow_ids from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  delete from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  v_product_scope := case when array_length(v_products,1)=2 then 'BOTH' else v_products[1] end;
  update public.sorting_trolley_intakes set customer_id=v_customer.customer_id, customer_code_snapshot=v_customer.customer_code, customer_name_snapshot=v_customer.customer_name, contents_status=v_contents, product_scope=v_product_scope, scheduled_for_date=p_scheduled_for_date, schedule_relation=v_relation, off_schedule_reason=null, off_schedule_code=null, correction_reason=v_reason, corrected_at=now(), corrected_by_auth_user_id=auth.uid(), revision_no=revision_no+1 where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id returning revision_no into v_revision;

  foreach v_product in array v_products loop
    select * into v_snapshot from public.sorting_schedule_product_snapshot(v_customer.customer_id,v_product,p_scheduled_for_date);
    v_new_flow_id := public.ensure_production_flow_item(v_customer.customer_id,v_product,p_scheduled_for_date,v_business_date,v_snapshot.schedule_version_id,v_snapshot.schedule_day_id,v_snapshot.schedule_product_id,v_snapshot.production_order,v_snapshot.route_id,v_snapshot.route_code,v_snapshot.route_display_name,v_snapshot.route_color);
    insert into public.sorting_trolley_intake_products(sorting_trolley_intake_id, product_code, scheduled_for_date, source_schedule_version_id, source_schedule_day_id, source_schedule_product_id, production_order_snapshot, planned_trolley_quantity_snapshot, route_id_snapshot, route_code_snapshot, route_display_name_snapshot, route_color_snapshot, production_flow_item_id) values(v_intake.sorting_trolley_intake_id, v_product, p_scheduled_for_date, v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id, v_snapshot.production_order, v_snapshot.planned_trolley_quantity, v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name, v_snapshot.route_color, v_new_flow_id);
    if v_downstream_wash_count>0 then
      update public.sorting_wash_run_customers wrc set customer_id=v_customer.customer_id, customer_code_snapshot=v_customer.customer_code, customer_name_snapshot=v_customer.customer_name, source_schedule_version_id=v_snapshot.schedule_version_id, source_schedule_day_id=v_snapshot.schedule_day_id, source_schedule_product_id=v_snapshot.schedule_product_id, production_order_snapshot=v_snapshot.production_order, scheduled_for_date=p_scheduled_for_date, schedule_relation=case when p_scheduled_for_date=v_business_date then 'TODAY' else 'UNSCHEDULED' end, production_flow_item_id=v_new_flow_id where wrc.production_flow_item_id=any(coalesce(v_old_flow_ids,array[]::uuid[])) and wrc.wash_type_snapshot=v_product;
      perform public.refresh_production_flow_wash_summary(v_new_flow_id);
    end if;
    perform public.append_production_flow_event(v_new_flow_id,'TROLLEY_INTAKE_CORRECTED','INTAKE',20,'SORTING',v_business_date,now(),v_intake.operator_staff_id,v_actor_staff_id,auth.uid(),'SORTING_V2','sorting_trolley_intake_revisions',v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,jsonb_build_object('reason',v_reason,'scheduled_for_date',p_scheduled_for_date,'schedule_relation',v_relation,'product_code',v_product));
  end loop;

  if v_old_flow_ids is not null then foreach v_new_flow_id in array v_old_flow_ids loop perform public.refresh_production_flow_wash_summary(v_new_flow_id); end loop; end if;
  select to_jsonb(sti) || jsonb_build_object('products',coalesce((select jsonb_agg(to_jsonb(stip) order by stip.product_code) from public.sorting_trolley_intake_products stip where stip.sorting_trolley_intake_id=sti.sorting_trolley_intake_id),'[]'::jsonb)) into v_after from public.sorting_trolley_intakes sti where sti.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  insert into public.sorting_trolley_intake_revisions(sorting_trolley_intake_id,revision_no,action_type,reason,before_data,after_data,changed_by_auth_user_id,changed_by_staff_id) values(v_intake.sorting_trolley_intake_id,v_revision,'CORRECTED',v_reason,v_before,v_after,auth.uid(),v_actor_staff_id);
  return jsonb_build_object('status','corrected','revision_no',v_revision,'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id);
end; $function$;

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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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

-- customer_kg_estimates_live(p_reference_date date, p_customer_id uuid)
CREATE OR REPLACE FUNCTION public.customer_kg_estimates_live(p_reference_date date, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(customer_id uuid, product_code text, production_weekday smallint, estimated_kg numeric, history_points integer, median_kg numeric, minimum_kg numeric, maximum_kg numeric, last_service_date date, last_service_kg numeric, carried_over_points integer, estimate_status text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
 SET enable_nestloop TO 'off'
AS $function$
  with slots as (
    select distinct v.customer_id,pt.product_code,d.production_weekday::smallint production_weekday
    from public.customer_schedule_versions v
    join public.customers c on c.customer_id=v.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code in ('CLOTHES','MOP')
    where v.status='PUBLISHED' and v.effective_from<=p_reference_date
      and (v.effective_until is null or v.effective_until>=p_reference_date)
      and (p_customer_id is null or v.customer_id=p_customer_id)
  ), recent as materialized (
    select h.* from public.customer_kg_service_history(p_reference_date,p_customer_id) h where h.recency_rank<=8
  ), medians as (
    select r.customer_id,r.product_code,r.production_weekday,
      percentile_cont(0.5) within group(order by r.service_kg)::numeric median_kg
    from recent r group by r.customer_id,r.product_code,r.production_weekday
  ), model as (
    select r.customer_id,r.product_code,r.production_weekday,count(*)::integer history_points,
      avg(least(greatest(r.service_kg,m.median_kg*0.4),m.median_kg*2)) capped_average_kg,
      m.median_kg,min(r.service_kg) minimum_kg,max(r.service_kg) maximum_kg,max(r.service_date) last_service_date,
      (array_agg(r.service_kg order by r.service_date desc))[1] last_service_kg,
      count(*) filter(where r.carried_over)::integer carried_over_points
    from recent r
    join medians m on m.customer_id=r.customer_id and m.product_code=r.product_code and m.production_weekday=r.production_weekday
    group by r.customer_id,r.product_code,r.production_weekday,m.median_kg
  )
  select s.customer_id,s.product_code,s.production_weekday,
    case when coalesce(m.history_points,0)>=3 then round(m.capped_average_kg,1) end,
    coalesce(m.history_points,0),round(m.median_kg,1),round(m.minimum_kg,1),round(m.maximum_kg,1),
    m.last_service_date,round(m.last_service_kg,1),coalesce(m.carried_over_points,0),
    case when coalesce(m.history_points,0)<3 then 'LEARNING'
         when m.last_service_date<p_reference_date-42 then 'STALE'
         else 'READY' end
  from slots s
  left join model m on m.customer_id=s.customer_id and m.product_code=s.product_code and m.production_weekday=s.production_weekday;
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']) then
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

-- distribution_route_valid_on_date(p_route_id uuid, p_work_date date)
CREATE OR REPLACE FUNCTION public.distribution_route_valid_on_date(p_route_id uuid, p_work_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select exists (
    select 1
    from public.distribution_routes r
    where r.route_id=p_route_id
      and r.active
      and r.deleted_at is null
      and (
        r.route_kind in ('COLLECTION','AD_HOC','SUPPORT')
        or exists (
          select 1
          from public.customer_schedule_versions v
          join public.customer_schedule_days d
            on d.schedule_version_id=v.schedule_version_id
          where v.status='PUBLISHED'
            and v.effective_from <= p_work_date
            and (v.effective_until is null or v.effective_until >= p_work_date)
            and d.active
            and d.default_route_id=r.route_id
            and d.delivery_weekday=extract(isodow from p_work_date)::smallint
        )
      )
  );
$function$;

-- finish_enforce_new_entry_current_shift()
CREATE OR REPLACE FUNCTION public.finish_enforce_new_entry_current_shift()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v_auto jsonb; v_expected_shift text;
begin
  if session_user = 'postgres' and auth.uid() is null
     and new.source_application = 'APPS_SCRIPT_CENTRALDB_20261023_001'
     and new.revision_no = 1
     and new.production_business_date between date '2026-09-26' and date '2026-10-23'
     and exists (
       select 1 from staging.apps_script_incremental_rows r
       where r.import_batch = new.source_application and r.decision = 'APPROVED'
         and r.source_sheet in ('FinishProduction','FinishProductionHistory')
         and r.after_snapshot->'plan'->>'kind' = 'FINISH'
         and (r.after_snapshot->'plan'->>'target_id')::uuid = new.finish_production_entry_id
         and (r.after_snapshot->'plan'->>'flow_id')::uuid = new.production_flow_item_id
         and (r.after_snapshot->'plan'->>'customer_id')::uuid = new.customer_id
         and (r.after_snapshot->'plan'->>'business_date')::date = new.production_business_date
         and (r.after_snapshot->'plan'->>'delivery_date')::date = new.delivery_date
         and (r.after_snapshot->'plan'->>'shift_id')::uuid = new.shift_id
         and r.after_snapshot->'plan'->>'shift_code' = new.shift_code_snapshot
         and (r.after_snapshot->'plan'->>'station_id')::uuid = new.station_id
         and r.after_snapshot->'plan'->>'station_code' = new.table_code_snapshot
         and (r.after_snapshot->'plan'->>'staff_id')::uuid = new.processed_by_staff_id
         and (r.after_snapshot->'plan'->>'recorded_at_local')::timestamp at time zone 'Europe/Dublin' = new.recorded_at
     ) then
    return new;
  end if;
  -- Original live and correction behaviour remains in force for every other row.
  if coalesce(new.revision_no,1)=1 then
    v_auto := public.get_finish_auto_shift_context(coalesce(new.recorded_at,now()));
    v_expected_shift := upper(coalesce(v_auto->>'recommended_shift_code',''));
    if v_expected_shift not in ('MORNING','EVENING') then
      raise exception using errcode='P0002', message='Current Finish operational shift could not be resolved.';
    end if;
    if upper(coalesce(new.shift_code_snapshot,''))<>v_expected_shift then
      raise exception using errcode='23514',
        message=format('New Finish production must use the current operational shift (%s). Switch Finish back to Auto/current shift and try again.',initcap(lower(v_expected_shift)));
    end if;
  end if;
  return new;
end;
$function$;

-- get_clothes_weekly_planner(p_effective_date date, p_production_weekday smallint, p_search text)
CREATE OR REPLACE FUNCTION public.get_clothes_weekly_planner(p_effective_date date DEFAULT current_business_date(), p_production_weekday smallint DEFAULT NULL::smallint, p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR'
    ]
  );

  if p_production_weekday is not null
     and p_production_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Production weekday must be between 1 and 7.';
  end if;

  with planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.operational_alert,
      route_visual.route_color as route_visual_color,
      p.schedule_product_id,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions as finish_instructions,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown,
      coalesce(trolley.has_shared_trolley, false) as has_shared_trolley
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
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
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'shared', served.product_count > 1,
            'serves_product_codes', served.product_codes,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
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
        join public.customer_schedule_products mp
          on mp.schedule_product_id = map.schedule_product_id
        join public.product_types pt2
          on pt2.product_type_id = mp.product_type_id
        where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
      ) served on true
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
      and d.active = true
      and p.active = true
      and pt.active = true
      and pt.deleted_at is null
      and pt.product_code = 'CLOTHES'
      and (p_production_weekday is null or d.production_weekday = p_production_weekday)
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'production_weekday', p_production_weekday,
    'search', v_search,
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'operational_alert', pr.operational_alert,
          'route_visual_color', pr.route_visual_color,
          'schedule_product_id', pr.schedule_product_id,
          'production_order', pr.production_order,
          'expected_kg', pr.expected_kg,
          'expected_units', pr.expected_units,
          'finish_instructions', pr.finish_instructions,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown,
          'has_shared_trolley', pr.has_shared_trolley
        )
        order by
          pr.production_weekday,
          pr.production_order nulls last,
          lower(pr.customer_name)
      ),
      '[]'::jsonb
    )
  ) into v_result
  from planner_rows pr;

  return v_result;
end;
$function$;

-- get_customer_directory(p_status text, p_service_filter text, p_search text, p_effective_date date, p_limit integer, p_offset integer)
CREATE OR REPLACE FUNCTION public.get_customer_directory(p_status text DEFAULT 'ACTIVE'::text, p_service_filter text DEFAULT 'ALL'::text, p_search text DEFAULT NULL::text, p_effective_date date DEFAULT current_business_date(), p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_status text := upper(trim(coalesce(p_status, 'ACTIVE')));
  v_service_filter text := upper(trim(coalesce(p_service_filter, 'ALL')));
  v_search text := nullif(trim(p_search), '');
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  );

  if v_status not in ('ACTIVE', 'INACTIVE', 'ALL') then
    raise exception using
      errcode = '22023',
      message = 'Invalid customer status filter.',
      detail = 'Allowed values: ACTIVE, INACTIVE, ALL.';
  end if;

  if v_service_filter not in (
    'ALL', 'CLOTHES', 'MOP',
    'CLOTHES_ONLY', 'MOP_ONLY', 'CLOTHES_AND_MOP'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Invalid customer service filter.',
      detail = 'Allowed values: ALL, CLOTHES, MOP, CLOTHES_ONLY, MOP_ONLY, CLOTHES_AND_MOP.';
  end if;

  with customer_base as (
    select
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.operational_alert,
      c.active,
      c.deactivated_at,
      c.deactivation_reason,
      c.row_version,
      coalesce(
        array_agg(pt.product_code order by pt.sort_order, pt.product_code)
          filter (where pt.product_code is not null),
        array[]::text[]
      ) as product_services
    from public.customers c
    left join public.customer_product_services s
      on s.customer_id = c.customer_id
     and s.active = true
     and s.deleted_at is null
     and s.effective_from <= p_effective_date
     and (s.effective_until is null or s.effective_until >= p_effective_date)
    left join public.product_types pt
      on pt.product_type_id = s.product_type_id
     and pt.active = true
     and pt.deleted_at is null
    where c.deleted_at is null
    group by
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.operational_alert,
      c.active,
      c.deactivated_at,
      c.deactivation_reason,
      c.row_version
  ),
  enriched as (
    select
      cb.*,
      cv.schedule_version_id,
      cv.version_number,
      cv.status as schedule_status,
      cv.effective_from,
      cv.effective_until,
      coalesce(sc.schedule_day_count, 0) as schedule_day_count,
      coalesce(sc.schedule_product_count, 0) as schedule_product_count
    from customer_base cb
    left join lateral (
      select
        v.schedule_version_id,
        v.version_number,
        v.status,
        v.effective_from,
        v.effective_until
      from public.customer_schedule_versions v
      where v.customer_id = cb.customer_id
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
    ) sc on true
  ),
  filtered as (
    select *
    from enriched e
    where
      (v_status = 'ALL'
       or (v_status = 'ACTIVE' and e.active)
       or (v_status = 'INACTIVE' and not e.active))
      and (
        v_service_filter = 'ALL'
        or (v_service_filter = 'CLOTHES' and 'CLOTHES' = any(e.product_services))
        or (v_service_filter = 'MOP' and 'MOP' = any(e.product_services))
        or (v_service_filter = 'CLOTHES_ONLY' and e.product_services = array['CLOTHES']::text[])
        or (v_service_filter = 'MOP_ONLY' and e.product_services = array['MOP']::text[])
        or (
          v_service_filter = 'CLOTHES_AND_MOP'
          and 'CLOTHES' = any(e.product_services)
          and 'MOP' = any(e.product_services)
        )
      )
      and (
        v_search is null
        or e.customer_name ilike '%' || v_search || '%'
        or e.customer_code ilike '%' || v_search || '%'
        or coalesce(e.eircode, '') ilike '%' || v_search || '%'
      )
  ),
  page_rows as (
    select *
    from filtered
    order by active desc, lower(customer_name), customer_code
    limit v_limit
    offset v_offset
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'status_filter', v_status,
    'service_filter', v_service_filter,
    'search', v_search,
    'limit', v_limit,
    'offset', v_offset,
    'total_count', (select count(*) from filtered),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'customer_id', p.customer_id,
            'customer_code', p.customer_code,
            'customer_name', p.customer_name,
            'eircode', p.eircode,
            'product_services', p.product_services,
            'active', p.active,
            'deactivated_at', p.deactivated_at,
            'deactivation_reason', p.deactivation_reason,
            'operational_alert', p.operational_alert,
            'row_version', p.row_version,
            'current_schedule', case
              when p.schedule_version_id is null then null
              else jsonb_build_object(
                'schedule_version_id', p.schedule_version_id,
                'version_number', p.version_number,
                'status', p.schedule_status,
                'effective_from', p.effective_from,
                'effective_until', p.effective_until,
                'schedule_day_count', p.schedule_day_count,
                'schedule_product_count', p.schedule_product_count
              )
            end
          )
          order by p.active desc, lower(p.customer_name), p.customer_code
        )
        from page_rows p
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
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
    or public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR'])
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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
    'can_edit_customers', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
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
    'can_view_distribution', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER',
        'DISTRIBUTION_OPERATOR', 'AUDITOR'
      ]
    )
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

-- get_customer_schedule_history(p_customer_id uuid)
CREATE OR REPLACE FUNCTION public.get_customer_schedule_history(p_customer_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_customer_name text;
  v_customer_code text;
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  );

  select customer_name, customer_code
  into v_customer_name, v_customer_code
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  select jsonb_build_object(
    'customer_id', p_customer_id,
    'customer_code', v_customer_code,
    'customer_name', v_customer_name,
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', v.schedule_version_id,
          'version_number', v.version_number,
          'status', v.status,
          'effective_from', v.effective_from,
          'effective_until', v.effective_until,
          'based_on_version_id', v.based_on_version_id,
          'source_code', v.source_code,
          'change_reason', v.change_reason,
          'created_at', v.created_at,
          'updated_at', v.updated_at,
          'published_at', v.published_at,
          'superseded_at', v.superseded_at,
          'cancelled_at', v.cancelled_at,
          'row_version', v.row_version,
          'schedule_day_count', counts.schedule_day_count,
          'schedule_product_count', counts.schedule_product_count,
          'trolley_requirement_count', counts.trolley_requirement_count,
          'is_effective_on_business_date',
            v.status = 'PUBLISHED'
            and public.current_business_date() >= v.effective_from
            and (
              v.effective_until is null
              or public.current_business_date() <= v.effective_until
            ),
          'can_restore_as_draft', v.status in ('PUBLISHED', 'SUPERSEDED')
        )
        order by v.version_number desc
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.customer_schedule_versions v
  left join lateral (
    select
      count(distinct d.schedule_day_id)::integer as schedule_day_count,
      count(distinct p.schedule_product_id)::integer as schedule_product_count,
      count(distinct req.schedule_trolley_requirement_id)::integer
        as trolley_requirement_count
    from public.customer_schedule_days d
    left join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    left join public.customer_schedule_trolley_requirements req
      on req.schedule_day_id = d.schedule_day_id
    where d.schedule_version_id = v.schedule_version_id
  ) counts on true
  where v.customer_id = p_customer_id;

  return v_result;
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
    and public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']);

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
  v_management := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR']
  );
  v_clothes := v_management or public.has_any_role(
    array['SORTING_OPERATOR', 'FINISH_OPERATOR']
  );
  v_mop := v_management or public.has_any_role(array['MOP_OPERATOR']);

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

  v_can_manage := public.has_any_role(array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR']);

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

-- get_distribution_roster_history(p_week_start date)
CREATE OR REPLACE FUNCTION public.get_distribution_roster_history(p_week_start date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  perform public.require_distribution_roster_read_access();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'roster_version_id',v.distribution_roster_version_id,
      'week_start',v.week_start,
      'version_number',v.version_number,
      'status',v.roster_status,
      'change_reason',v.change_reason,
      'notes',v.roster_note,
      'created_at',v.created_at,
      'published_at',v.published_at,
      'superseded_at',v.superseded_at,
      'row_version',v.row_version
    ) order by v.version_number desc)
    from public.distribution_roster_versions v
    where v.week_start=p_week_start
  ),'[]'::jsonb);
end;
$function$;

-- get_finish_delivery_reconciliation_context(p_at timestamp with time zone)
CREATE OR REPLACE FUNCTION public.get_finish_delivery_reconciliation_context(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_now timestamptz:=coalesce(p_at,now());
  v_local_date date:=(coalesce(p_at,now()) at time zone 'Europe/Dublin')::date;
  v_items jsonb;
begin
  perform public.require_finish_production_access();

  with due as (
    select
      pfi.production_flow_item_id,pfi.customer_name_snapshot,pfi.customer_code_snapshot,
      pfi.scheduled_for_date,pfi.route_code_snapshot,pfi.route_display_name_snapshot,
      pfi.washed_kg_total,pfi.washed_trace_count,
      public.next_distribution_business_date(pfi.scheduled_for_date) as delivery_date,
      rec.outcome_code,rec.next_prompt_at,rec.acknowledged_at
    from public.production_flow_items pfi
    left join public.finish_delivery_reconciliations rec
      on rec.production_flow_item_id=pfi.production_flow_item_id
    where pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date is not null
      
and coalesce(pfi.washed_trace_count,0)>0
      and exists (
        select 1
        from public.production_flow_events wash_event
        where wash_event.production_flow_item_id=pfi.production_flow_item_id
          and wash_event.event_type='WASH_RECORDED'
          and left(coalesce(wash_event.source_application,''),4)<>'SIM_'
      )
      and public.next_distribution_business_date(pfi.scheduled_for_date)<=v_local_date
      and v_now>=public.finish_delivery_cutoff(public.next_distribution_business_date(pfi.scheduled_for_date))
      and not exists (
        select 1
        from public.finish_production_entries entry
        join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
        where entry.production_flow_item_id=pfi.production_flow_item_id
          and entry.status='ACTIVE' and line.quantity>0
      )
      and coalesce(rec.outcome_code,'')<>'PROCESSED_CONFIRMED'
      and (rec.next_prompt_at is null or rec.next_prompt_at<=v_now)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'production_flow_item_id',production_flow_item_id,
    'customer_name',customer_name_snapshot,
    'customer_code',customer_code_snapshot,
    'scheduled_for_date',scheduled_for_date,
    'delivery_date',delivery_date,
    'overdue_days',greatest(v_local_date-delivery_date,0),
    'route_code',route_code_snapshot,
    'route_name',route_display_name_snapshot,
    'washed_kg_total',washed_kg_total,
    'washed_trace_count',washed_trace_count,
    'previous_outcome_code',outcome_code,
    'previous_acknowledged_at',acknowledged_at
  ) order by delivery_date,scheduled_for_date,customer_name_snapshot),'[]'::jsonb)
  into v_items
  from due;

  return jsonb_build_object(
    'schema_version','FINISH_DELIVERY_RECONCILIATION_V1',
    'local_date',v_local_date,
    'pending_count',jsonb_array_length(v_items),
    'items',v_items
  );
end;
$function$;

-- get_mop_weekly_planner(p_effective_date date, p_production_weekday smallint, p_search text)
CREATE OR REPLACE FUNCTION public.get_mop_weekly_planner(p_effective_date date DEFAULT current_business_date(), p_production_weekday smallint DEFAULT NULL::smallint, p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'MOP_OPERATOR', 'AUDITOR', 'DISTRIBUTION_OPERATOR'
    ]
  );

  if p_production_weekday is not null
     and p_production_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Production weekday must be between 1 and 7.';
  end if;

  with planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.operational_alert,
      route_visual.route_color as route_visual_color,
      p.schedule_product_id,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions as mop_instructions,
      coalesce(variants.product_variants, array[]::text[]) as mop_products,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
    left join lateral (
      select array_agg(pv.display_name order by pv.sort_order, pv.display_name)
        as product_variants
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
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
      and d.active = true
      and p.active = true
      and pt.active = true
      and pt.deleted_at is null
      and pt.product_code = 'MOP'
      and (p_production_weekday is null or d.production_weekday = p_production_weekday)
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'production_weekday', p_production_weekday,
    'search', v_search,
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'operational_alert', pr.operational_alert,
          'route_visual_color', pr.route_visual_color,
          'schedule_product_id', pr.schedule_product_id,
          'production_order', pr.production_order,
          'expected_kg', pr.expected_kg,
          'expected_units', pr.expected_units,
          'mop_instructions', pr.mop_instructions,
          'mop_products', pr.mop_products,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown
        )
        order by
          pr.production_weekday,
          pr.production_order nulls last,
          lower(pr.customer_name)
      ),
      '[]'::jsonb
    )
  ) into v_result
  from planner_rows pr;

  return v_result;
end;
$function$;

-- get_sorting_staff_dashboard_context_v2(p_shift_code text)
CREATE OR REPLACE FUNCTION public.get_sorting_staff_dashboard_context_v2(p_shift_code text DEFAULT 'MORNING'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_base jsonb;
  v_business_date date;
  v_shift_id uuid;
  v_staff jsonb := '[]'::jsonb;
  v_available_count integer := 0;
  v_confirmed_absent_count integer := 0;
  v_auto_absent_count integer := 0;
  v_moved_count integer := 0;
  v_effective_mop_count integer := 0;
  v_effective_mop_staff_id uuid;
  v_effective_mop_staff_name text;
  v_effective_mop_staff jsonb := '[]'::jsonb;
  v_effective_mop_staff_names text;
  v_operational_mop_coverage text := 'UNRESOLVED';
begin
  v_base := public.get_sorting_staff_dashboard_context(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select coalesce(jsonb_agg(
    staff_row.value || jsonb_build_object(
      'actual_in_sorting', transfer.work_session_id is null,
      'actual_area_code', coalesce(transfer.area_code, 'SORTING'),
      'actual_area_name', coalesce(transfer.area_name, 'Sorting Area'),
      'area_transfer_work_session_id', transfer.work_session_id,
      'area_transfer_notes', transfer.notes,
      'area_transfer_at', case
        when transfer.moved_at is null then null
        else to_char(transfer.moved_at at time zone 'Europe/Dublin', 'HH24:MI')
      end,
      'partial_area_transfer', transfer.work_session_id is not null and partial.is_partial,
      'attendance_status', case
        when transfer.work_session_id is not null then 'MOVED'
        else staff_row.value ->> 'attendance_status'
      end,
      'attendance_source', case
        when transfer.work_session_id is not null then 'ACTUAL_AREA_TRANSFER'
        else staff_row.value ->> 'attendance_source'
      end,
      'performance', case
        when transfer.work_session_id is not null and not partial.is_partial then
          coalesce(staff_row.value -> 'performance', '{}'::jsonb) || jsonb_build_object(
            'worked_minutes', 0,
            'worked_hours', 0,
            'clothes_kg_hr', null,
            'clothes_target_pct', null,
            'mop_kg_hr', null,
            'mop_target_pct', null
          )
        else staff_row.value -> 'performance'
      end,
      'trolley_intake_count', (
        select count(*)::integer
        from public.sorting_trolley_intakes sti
        where sti.business_date = v_business_date
          and sti.shift_id = v_shift_id
          and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      ),
      'has_actual_operational_activity',
        transfer.work_session_id is not null
        or coalesce((staff_row.value -> 'performance' ->> 'total_loads')::integer, 0) > 0
        or exists (
          select 1
          from public.sorting_trolley_intakes sti
          where sti.business_date = v_business_date
            and sti.shift_id = v_shift_id
            and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
        )
        or coalesce((staff_row.value ->> 'adjusted')::boolean, false)
        or coalesce((staff_row.value ->> 'manual_position')::boolean, false)
    )
    order by
      case
        when transfer.work_session_id is not null then 2
        when staff_row.value ->> 'attendance_status' in ('ABSENT','AUTO_ABSENT') then 1
        else 0
      end,
      lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join lateral (
    select ws.work_session_id, a.area_code, a.area_name, ws.notes, ws.actual_start_at as moved_at
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift_id
      and ws.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      and ws.source in ('SORTING_AREA_TRANSFER', 'SORTING_TO_FINISH_TRANSFER')
      and a.area_code <> 'SORTING'
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1
  ) transfer on true
  cross join lateral (
    select nullif(staff_row.value ->> 'work_session_id', '') is not null
      and nullif(staff_row.value ->> 'work_session_id', '')::uuid is distinct from transfer.work_session_id as is_partial
  ) partial;

  select
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'AUTO_ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'MOVED'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
        and staff_row.value ->> 'work_mode' = 'MOP'
    )::integer
  into
    v_available_count,
    v_confirmed_absent_count,
    v_auto_absent_count,
    v_moved_count,
    v_effective_mop_count
  from jsonb_array_elements(v_staff) staff_row;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'staff_id', nullif(staff_row.value ->> 'staff_id', '')::uuid,
      'display_name', staff_row.value ->> 'display_name'
    ) order by ord), '[]'::jsonb),
    string_agg(staff_row.value ->> 'display_name', ' & ' order by ord)
  into v_effective_mop_staff, v_effective_mop_staff_names
  from jsonb_array_elements(v_staff) with ordinality staff_row(value, ord)
  where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
    and staff_row.value ->> 'work_mode' = 'MOP';

  v_effective_mop_staff_id := nullif(v_effective_mop_staff -> 0 ->> 'staff_id', '')::uuid;
  v_effective_mop_staff_name := v_effective_mop_staff -> 0 ->> 'display_name';

  v_operational_mop_coverage := case
    when v_available_count = 0 then 'NO_PRESENT_SORTING_STAFF'
    when v_effective_mop_count between 1 and 2 then 'DEDICATED'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'NO_DEDICATED_MOP'
      then 'NO_DEDICATED_MOP'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'DEDICATED'
      then 'UNRESOLVED_ABSENT_MOP'
    else 'UNRESOLVED'
  end;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'attendance_summary', jsonb_build_object(
      'shown_staff', jsonb_array_length(v_staff),
      'available_in_sorting', v_available_count,
      'not_absent', v_available_count,
      'confirmed_absent', v_confirmed_absent_count,
      'auto_absent', v_auto_absent_count,
      'moved_to_other_area', v_moved_count,
      'absent_total', v_confirmed_absent_count + v_auto_absent_count
    ),
    'operational_mop_coverage', v_operational_mop_coverage,
    'operational_mop_staff_id', v_effective_mop_staff_id,
    'operational_mop_staff_name', v_effective_mop_staff_name,
    'operational_mop_staff', v_effective_mop_staff,
    'operational_mop_staff_names', v_effective_mop_staff_names,
    'actual_activity_sources', jsonb_build_array(
      'WASHING','TROLLEY_INTAKE','TIME_ADJUSTMENT','MANUAL_POSITION','AREA_TRANSFER'
    )
  );
end;
$function$;

-- get_sorting_trolley_intake_context_v2(p_shift_code text)
CREATE OR REPLACE FUNCTION public.get_sorting_trolley_intake_context_v2(p_shift_code text DEFAULT 'MORNING'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_id uuid;
  v_board jsonb := '[]'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if v_shift_id is null then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  with board_days as (
    select v_business_date-1 as scheduled_for_date, 'YESTERDAY'::text as day_relation, -1 as day_offset
    union all
    select v_business_date, 'TODAY'::text, 0
    union all
    select gs::date as scheduled_for_date, case when gs::date=v_business_date+1 then 'TOMORROW' else 'FUTURE' end::text as day_relation, (gs::date-v_business_date)::integer as day_offset
    from generate_series(v_business_date+1, v_business_date+7, interval '1 day') gs
  ),
  scheduled as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      r.route_id,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      coalesce((
        select sum(req.quantity)::integer
        from public.customer_schedule_trolley_requirements req
        where req.schedule_day_id=sd.schedule_day_id
          and req.owner_schedule_product_id=sp.schedule_product_id
          and req.active=true
      ),0) as planned_trolley_quantity,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id',req.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'quantity',req.quantity,
            'empty_trolley',req.empty_trolley
          )
          order by tt.sort_order,tt.display_code,tt.trolley_type_code
        )
        from public.customer_schedule_trolley_requirements req
        join public.trolley_types tt
          on tt.trolley_type_id=req.trolley_type_id
         and tt.active=true
         and tt.deleted_at is null
        where req.schedule_day_id=sd.schedule_day_id
          and req.owner_schedule_product_id=sp.schedule_product_id
          and req.active=true
      ),'[]'::jsonb) as trolley_requirements
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status='PUBLISHED'
     and csv.effective_from<=bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until>=bd.scheduled_for_date)
    join public.customers c
      on c.customer_id=csv.customer_id
     and c.active=true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id=csv.schedule_version_id
     and sd.active=true
     and sd.production_weekday=extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id=sd.schedule_day_id
     and sp.active=true
    join public.product_types pt
      on pt.product_type_id=sp.product_type_id
     and pt.active=true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES','MOP')
    left join public.distribution_routes r
      on r.route_id=sd.default_route_id
     and r.deleted_at is null
  ),
  enriched as (
    select
      s.*,
      coalesce(i.received_count,0) as received_count,
      coalesce(i.contents_count,0) as contents_count,
      coalesce(i.empty_count,0) as empty_count,
      coalesce(i.review_count,0) as review_count,
      i.first_received_at,
      i.last_received_at,
      coalesce(i.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(w.wash_count,0) as wash_count,
      w.last_wash_code,
      pfi.production_flow_item_id,
      coalesce(pfi.washed_kg_total,0) as flow_washed_kg,
      public.sorting_trolley_receipt_status(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0)
      ) as receipt_status,
      public.sorting_trolley_intake_state(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0),
        coalesce(i.contents_count,0),
        coalesce(i.empty_count,0),
        coalesce(w.wash_count,0),
        coalesce(i.review_count,0)
      ) as operational_state
    from scheduled s
    left join lateral (
      select
        count(*)::integer as received_count,
        count(*) filter (where sti.contents_status='CONTENTS')::integer as contents_count,
        count(*) filter (where sti.contents_status='EMPTY')::integer as empty_count,
        count(*) filter (where sti.review_status in ('PENDING','UNDER_REVIEW'))::integer as review_count,
        min(sti.arrived_at) as first_received_at,
        max(sti.arrived_at) as last_received_at,
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',sti.trolley_code_snapshot,
            'trolley_type_code',tt.trolley_type_code,
            'trolley_display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'contents_status',sti.contents_status,
            'arrived_at',sti.arrived_at,
            'review_status',sti.review_status
          )
          order by sti.arrived_at
        ) as trolley_codes
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti
        on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      join public.trolleys t
        on t.trolley_id=sti.trolley_id
      join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
      where stip.source_schedule_product_id=s.schedule_product_id
        and stip.scheduled_for_date=s.scheduled_for_date
        and sti.customer_id=s.customer_id
        and coalesce(sti.record_status,'RECORDED')='RECORDED'
    ) i on true
    left join lateral (
      select
        count(*)::integer as wash_count,
        (
          select wr2.wash_code
          from public.sorting_wash_run_customers wrc2
          join public.sorting_wash_runs wr2 on wr2.wash_run_id=wrc2.wash_run_id
          where wr2.status='RECORDED'
            and wrc2.customer_id=s.customer_id
            and wrc2.source_schedule_product_id=s.schedule_product_id
            and wrc2.scheduled_for_date=s.scheduled_for_date
          order by wr2.started_at desc,wr2.created_at desc
          limit 1
        ) as last_wash_code
      from public.sorting_wash_run_customers wrc
      join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id
      where wr.status='RECORDED'
        and wrc.customer_id=s.customer_id
        and wrc.source_schedule_product_id=s.schedule_product_id
        and wrc.scheduled_for_date=s.scheduled_for_date
    ) w on true
    left join public.production_flow_items pfi
      on pfi.customer_id=s.customer_id
     and pfi.product_code=s.product_code
     and pfi.scheduled_for_date=s.scheduled_for_date
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',e.customer_id,
      'customer_code',e.customer_code,
      'customer_name',e.customer_name,
      'product_code',e.product_code,
      'scheduled_for_date',e.scheduled_for_date,
      'day_relation',e.day_relation,
      'day_offset',e.day_offset,
      'production_order',e.production_order,
      'production_instructions',e.production_instructions,
      'schedule_version_id',e.schedule_version_id,
      'schedule_day_id',e.schedule_day_id,
      'schedule_product_id',e.schedule_product_id,
      'route_id',e.route_id,
      'route_code',e.route_code,
      'route_display_name',e.route_display_name,
      'route_color',e.route_color,
      'planned_trolley_quantity',e.planned_trolley_quantity,
      'trolley_requirements',e.trolley_requirements,
      'received_count',e.received_count,
      'contents_count',e.contents_count,
      'empty_count',e.empty_count,
      'review_count',e.review_count,
      'receipt_status',e.receipt_status,
      'operational_state',e.operational_state,
      'nothing_to_wash',e.operational_state='NOTHING_TO_WASH',
      'waiting_wash',e.operational_state='WAITING_WASH',
      'wash_count',e.wash_count,
      'last_wash_code',e.last_wash_code,
      'first_received_at',e.first_received_at,
      'last_received_at',e.last_received_at,
      'trolleys',e.trolley_codes,
      'production_flow_item_id',e.production_flow_item_id,
      'flow_washed_kg',e.flow_washed_kg
    )
    order by
      e.day_offset,
      case e.product_code when 'CLOTHES' then 1 else 2 end,
      e.production_order nulls last,
      lower(e.customer_name)
  ),'[]'::jsonb)
  into v_board
  from enriched e;

  with board as (
    select value as row
    from jsonb_array_elements(v_board)
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',row->>'customer_id',
      'customer_name',row->>'customer_name',
      'product_code',row->>'product_code',
      'scheduled_for_date',row->>'scheduled_for_date',
      'day_relation',row->>'day_relation',
      'route_code',row->>'route_code',
      'route_display_name',row->>'route_display_name',
      'route_color',row->>'route_color',
      'received_count',(row->>'received_count')::integer,
      'planned_trolley_quantity',(row->>'planned_trolley_quantity')::integer,
      'first_received_at',row->>'first_received_at',
      'production_flow_item_id',row->>'production_flow_item_id'
    )
    order by (row->>'first_received_at')::timestamptz,
             (row->>'production_order')::integer nulls last,
             lower(row->>'customer_name')
  ),'[]'::jsonb)
  into v_queue
  from board
  where row->>'operational_state'='WAITING_WASH'
    and row->>'day_relation' in ('TODAY','TOMORROW','FUTURE');

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'sorting_trolley_intake_id',q.sorting_trolley_intake_id,
      'trolley_code',q.trolley_code_snapshot,
      'customer_id',q.customer_id,
      'customer_name',q.customer_name_snapshot,
      'business_date',q.business_date,
      'physical_received_on',q.physical_received_on,
      'shift_code',q.shift_code_snapshot,
      'arrived_at',q.arrived_at,
      'contents_status',q.contents_status,
      'product_scope',q.product_scope,
      'scheduled_for_date',q.scheduled_for_date,
      'schedule_relation',q.schedule_relation,
      'review_status',q.review_status,
      'exception_type',q.exception_type,
      'operator_staff_id',q.operator_staff_id,
      'operator_name',operator.display_name,
      'notes',q.notes,
      'record_status',coalesce(q.record_status,'RECORDED'),
      'revision_no',q.revision_no,
      'correction_reason',q.correction_reason,
      'cancellation_reason',q.cancellation_reason,
      'corrected_at',q.corrected_at,
      'cancelled_at',q.cancelled_at,
      'products',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'product_code',p.product_code,
            'production_flow_item_id',p.production_flow_item_id,
            'route_code',p.route_code_snapshot,
            'route_display_name',p.route_display_name_snapshot
          )
          order by p.product_code
        )
        from public.sorting_trolley_intake_products p
        where p.sorting_trolley_intake_id=q.sorting_trolley_intake_id
      ),'[]'::jsonb)
    )
    order by q.arrived_at desc
  ),'[]'::jsonb)
  into v_recent
  from (
    select *
    from public.sorting_trolley_intakes sti
    where sti.business_date=v_business_date
      and sti.shift_id=v_shift_id
    order by sti.arrived_at desc
    limit 30
  ) q
  left join public.staff_members operator
    on operator.staff_id=q.operator_staff_id;

  return jsonb_build_object(
    'business_date',v_business_date,
    'physical_date',current_date,
    'shift_code',upper(trim(p_shift_code)),
    'board',v_board,
    'waiting_queue',v_queue,
    'recent_intakes',v_recent,
    'summary',jsonb_build_object(
      'received_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
      ),
      'contents_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='CONTENTS'
      ),
      'empty_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='EMPTY'
      ),
      'waiting_wash',jsonb_array_length(v_queue)
    ),
    'source','PUBLISHED_SCHEDULE_PLUS_PHYSICAL_TROLLEY_INTAKE'
  );
end;
$function$;

-- get_sorting_trolley_intake_context_v3(p_shift_code text)
CREATE OR REPLACE FUNCTION public.get_sorting_trolley_intake_context_v3(p_shift_code text DEFAULT 'MORNING'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_base jsonb := public.get_sorting_trolley_intake_context_v2(p_shift_code);
  v_board jsonb := '[]'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_no_trolley_recent jsonb := '[]'::jsonb;
  v_business_date date := (v_base->>'business_date')::date;
begin
  perform public.require_sorting_operational_access();

  select coalesce(jsonb_agg(
    b.value || jsonb_build_object(
      'trolley_reception_expected',req.has_trolley,
      'no_trolley_eligible',not req.has_trolley,
      'no_trolley_arrival_count',coalesce(nta.arrival_count,0),
      'no_trolley_arrival_at',nta.last_arrived_at,
      'receipt_evidence_count',coalesce((b.value->>'received_count')::integer,0)+coalesce(nta.arrival_count,0),
      'receipt_status',case
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then 'NO_TROLLEY_RECEIVED'
        when not req.has_trolley then 'WAITING_NO_TROLLEY_CONFIRMATION'
        else b.value->>'receipt_status'
      end,
      'operational_state',case
        when coalesce((b.value->>'wash_count')::integer,0)>0 then 'WASHING_RECORDED'
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then 'WAITING_WASH'
        when not req.has_trolley then 'WAITING_RECEIPT'
        else b.value->>'operational_state'
      end,
      'waiting_wash',case
        when coalesce((b.value->>'wash_count')::integer,0)>0 then false
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then true
        else coalesce((b.value->>'waiting_wash')::boolean,false)
      end,
      'reception_evidence_source',case
        when coalesce(nta.arrival_count,0)>0 then 'NO_TROLLEY_CONTENTS'
        when coalesce((b.value->>'received_count')::integer,0)>0 then 'PHYSICAL_TROLLEY'
        else 'NONE'
      end
    )
    order by (b.value->>'day_offset')::integer,
             case b.value->>'product_code' when 'CLOTHES' then 1 else 2 end,
             nullif(b.value->>'production_order','')::integer nulls last,
             lower(b.value->>'customer_name')
  ),'[]'::jsonb)
  into v_board
  from jsonb_array_elements(coalesce(v_base->'board','[]'::jsonb)) b
  left join lateral (
    select public.sorting_schedule_product_has_trolley(
      nullif(b.value->>'schedule_product_id','')::uuid
    ) as has_trolley
  ) req on true
  left join lateral (
    select count(*)::integer as arrival_count,max(a.arrived_at) as last_arrived_at
    from public.sorting_non_trolley_arrivals a
    where a.status='RECORDED'
      and a.customer_id=nullif(b.value->>'customer_id','')::uuid
      and a.source_schedule_product_id=nullif(b.value->>'schedule_product_id','')::uuid
      and a.scheduled_for_date=nullif(b.value->>'scheduled_for_date','')::date
  ) nta on true;

  select coalesce(jsonb_agg(q.value order by
    case q.value->>'day_relation' when 'TODAY' then 0 when 'TOMORROW' then 1 when 'FUTURE' then 2 else 3 end,
    nullif(q.value->>'production_order','')::integer nulls last,
    lower(q.value->>'customer_name')
  ),'[]'::jsonb)
  into v_queue
  from jsonb_array_elements(v_board) q
  where q.value->>'operational_state'='WAITING_WASH'
    and q.value->>'day_relation' in ('TODAY','TOMORROW','FUTURE');

  select coalesce(jsonb_agg(jsonb_build_object(
    'sorting_non_trolley_arrival_id',a.sorting_non_trolley_arrival_id,
    'arrival_mode','NO_TROLLEY',
    'trolley_code','NO TROLLEY',
    'customer_id',a.customer_id,
    'customer_name',a.customer_name_snapshot,
    'business_date',a.business_date,
    'physical_received_on',a.physical_received_on,
    'shift_code',a.shift_code_snapshot,
    'arrived_at',a.arrived_at,
    'contents_status','CONTENTS',
    'product_scope',a.product_code,
    'scheduled_for_date',a.scheduled_for_date,
    'schedule_relation',case
      when a.scheduled_for_date=v_business_date then 'TODAY'
      when a.scheduled_for_date=v_business_date+1 then 'TOMORROW'
      when a.scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      else 'OFF_SCHEDULE' end,
    'review_status','NOT_REQUIRED',
    'operator_staff_id',a.operator_staff_id,
    'operator_name',sm.display_name,
    'notes',a.notes,
    'products',jsonb_build_array(jsonb_build_object(
      'product_code',a.product_code,
      'production_flow_item_id',a.production_flow_item_id
    ))
  ) order by a.arrived_at desc),'[]'::jsonb)
  into v_no_trolley_recent
  from public.sorting_non_trolley_arrivals a
  left join public.staff_members sm on sm.staff_id=a.operator_staff_id
  where a.business_date=v_business_date
    and a.shift_code_snapshot=upper(trim(p_shift_code))
    and a.status='RECORDED';

  return v_base || jsonb_build_object(
    'board',v_board,
    'waiting_queue',v_queue,
    'recent_intakes',v_no_trolley_recent || coalesce(v_base->'recent_intakes','[]'::jsonb),
    'summary',coalesce(v_base->'summary','{}'::jsonb) || jsonb_build_object(
      'no_trolley_received_today',(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'received_today',coalesce((v_base->'summary'->>'received_today')::integer,0)+(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'contents_today',coalesce((v_base->'summary'->>'contents_today')::integer,0)+(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'waiting_wash',jsonb_array_length(v_queue)
    ),
    'source','PUBLISHED_SCHEDULE_PLUS_TROLLEY_OR_CONTROLLED_NO_TROLLEY_CONTENTS'
  );
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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

-- publish_distribution_roster(p_week_start date, p_change_reason text)
CREATE OR REPLACE FUNCTION public.publish_distribution_roster(p_week_start date, p_change_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_draft public.distribution_roster_versions%rowtype;
  v_old public.distribution_roster_versions%rowtype;
  v_driver record;
  v_date date;
  v_entry public.distribution_roster_entries%rowtype;
  v_block text;
begin
  perform public.require_distribution_roster_manage_access();

  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'Week start must be a Monday.' using errcode='22023';
  end if;

  select * into v_draft
  from public.distribution_roster_versions
  where week_start=p_week_start and roster_status='DRAFT'
  for update;

  if v_draft.distribution_roster_version_id is null then
    raise exception 'No Distribution roster draft exists for this week.' using errcode='22023';
  end if;

  for v_driver in
    select d.*
    from public.distribution_drivers d
    where d.deleted_at is null
      and d.employment_status='ACTIVE'
      and not coalesce(d.roster_hidden,false)
      and (d.joined_on is null or d.joined_on <= p_week_start+6)
      and (d.deactivated_on is null or d.deactivated_on >= p_week_start)
  loop
    for v_date in
      select g::date
      from generate_series(p_week_start,p_week_start+6,interval '1 day') g
    loop
      if v_driver.joined_on is not null and v_driver.joined_on>v_date then continue; end if;
      if v_driver.deactivated_on is not null and v_driver.deactivated_on<v_date then continue; end if;

      select * into v_entry
      from public.distribution_roster_entries
      where distribution_roster_version_id=v_draft.distribution_roster_version_id
        and primary_driver_id=v_driver.driver_id
        and work_date=v_date;

      if v_entry.distribution_roster_entry_id is null then
        raise exception 'Cannot publish: % has no assignment for %.',v_driver.display_name,v_date using errcode='22023';
      end if;

      if v_entry.assignment_status='PLANNED' then
        if v_entry.route_id is null or v_entry.vehicle_id is null then
          raise exception 'Cannot publish: % on % is missing route or vehicle.',v_driver.display_name,v_date using errcode='22023';
        end if;

        if not public.distribution_route_valid_on_date(v_entry.route_id,v_date) then
          raise exception 'Cannot publish: route for % on % is no longer valid.',v_driver.display_name,v_date using errcode='22023';
        end if;

        v_block := public.distribution_vehicle_block_reason(v_entry.vehicle_id,v_date);
        if v_block is not null then
          raise exception 'Cannot publish: vehicle for % on % is unavailable: %',v_driver.display_name,v_date,v_block using errcode='22023';
        end if;
      end if;
    end loop;
  end loop;

  select * into v_old
  from public.distribution_roster_versions
  where week_start=p_week_start and roster_status='PUBLISHED'
  for update;

  if v_old.distribution_roster_version_id is not null then
    update public.distribution_roster_versions
    set roster_status='SUPERSEDED',
        superseded_at=now(),
        superseded_by=auth.uid(),
        updated_by=auth.uid(),
        row_version=row_version+1
    where distribution_roster_version_id=v_old.distribution_roster_version_id;
  end if;

  update public.distribution_roster_versions
  set roster_status='PUBLISHED',
      published_at=now(),
      published_by=auth.uid(),
      updated_by=auth.uid(),
      change_reason=coalesce(nullif(trim(p_change_reason),''),change_reason),
      row_version=row_version+1
  where distribution_roster_version_id=v_draft.distribution_roster_version_id;

  if to_regclass('public.distribution_roster_events') is not null then
    insert into public.distribution_roster_events(
      distribution_roster_version_id,event_type,event_payload,recorded_by
    ) values (
      v_draft.distribution_roster_version_id,
      'PUBLISHED',
      jsonb_build_object('source','DISTRIBUTION_WEEKLY_ROSTER_V2'),
      auth.uid()
    );
  end if;

  return public.get_distribution_roster_context(p_week_start);
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'DISTRIBUTION_OPERATOR']) then
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

-- record_finish_rewash_v1(p_shift_code text, p_table_code text, p_processed_by_staff_id uuid, p_lines jsonb, p_notes text)
CREATE OR REPLACE FUNCTION public.record_finish_rewash_v1(p_shift_code text, p_table_code text, p_processed_by_staff_id uuid, p_lines jsonb, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_processor public.staff_members%rowtype;
  v_existing public.finish_rewash_entries%rowtype;
  v_saved public.finish_rewash_entries%rowtype;
  v_business_date date;
  v_actor uuid;
  v_entry_id uuid:=gen_random_uuid();
  v_group_id uuid;
  v_line jsonb;
  v_line_no integer:=0;
  v_customer_id uuid;
  v_customer_code text;
  v_customer_name text;
  v_service_codes text[];
  v_scheduled_days text[];
  v_batch text;
  v_kg numeric;
  v_clean jsonb:='[]'::jsonb;
  v_total_kg numeric:=0;
  v_before jsonb;
begin
  perform public.require_finish_production_access();
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023',message='Choose the Morning or Evening Finish shift.';
  end if;
  select st.* into v_station
  from public.stations st join public.areas a on a.area_id=st.area_id
  where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then
    raise exception using errcode='22023',message='Choose Finish Table 1, Table 2 or Table 3.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023',message='Add at least one ReWash customer line.';
  end if;

  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select * into v_processor from public.finish_assert_processing_staff(
    p_processed_by_staff_id,v_business_date,v_shift.shift_id,v_station.station_id,now()
  );
  if not found then
    raise exception using errcode='22023',message='Select a staff member working on this Finish Table and Shift.';
  end if;

  select * into v_existing from public.finish_rewash_entries
  where production_business_date=v_business_date and shift_code_snapshot=v_shift.shift_code and table_code_snapshot=v_station.station_code and status='ACTIVE'
  for update;
  v_group_id:=coalesce(v_existing.entry_group_id,v_entry_id);

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_line_no:=v_line_no+1;
    begin v_customer_id:=nullif(v_line->>'customer_id','')::uuid; exception when others then v_customer_id:=null; end;
    begin v_kg:=(v_line->>'quantity_kg')::numeric; exception when others then v_kg:=null; end;
    v_batch:=upper(nullif(trim(v_line->>'batch_reference'),''));
    if v_customer_id is null then raise exception using errcode='22023',message='Choose a valid customer for every ReWash line.'; end if;
    if v_kg is null or v_kg<=0 or v_kg>10000 then raise exception using errcode='22023',message='Each ReWash customer needs a KG value greater than zero.'; end if;
    if v_batch is not null and length(v_batch)>120 then raise exception using errcode='22023',message='A ReWash batch reference is too long.'; end if;

    select
      opt->>'customer_code',
      opt->>'customer_name',
      array(select jsonb_array_elements_text(coalesce(opt->'service_codes','[]'::jsonb))),
      coalesce(nullif(array(select jsonb_array_elements_text(coalesce(v_line->'scheduled_days','[]'::jsonb))),array[]::text[]),array(select jsonb_array_elements_text(coalesce(opt->'scheduled_days','[]'::jsonb))))
    into v_customer_code,v_customer_name,v_service_codes,v_scheduled_days
    from jsonb_array_elements(public.finish_rewash_customer_options_v1(v_business_date)) opt
    where opt->>'customer_id'=v_customer_id::text
    limit 1;
    if not found then raise exception using errcode='22023',message='ReWash customers must be active customers from the master customer schedule.'; end if;

    if v_batch is not null and exists (
      select 1
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and lower(l.batch_reference)=lower(v_batch)
      union all
      select 1
      from public.finish_rewash_entries e
      join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and lower(coalesce(l.batch_reference,''))=lower(v_batch)
        and e.entry_group_id<>v_group_id
    ) then
      raise exception using errcode='23505',message=format('Batch %s is already used by another active Finish record today.',v_batch);
    end if;

    v_clean:=v_clean||jsonb_build_array(jsonb_build_object(
      'line_no',v_line_no,'customer_id',v_customer_id,'customer_code',v_customer_code,'customer_name',v_customer_name,
      'service_codes',to_jsonb(v_service_codes),'scheduled_days',to_jsonb(v_scheduled_days),'batch_reference',v_batch,'quantity_kg',v_kg
    ));
    v_total_kg:=v_total_kg+v_kg;
  end loop;

  v_actor:=public.current_staff_id();
  v_before:=case when v_existing.finish_rewash_entry_id is null then null else to_jsonb(v_existing) end;
  if v_existing.finish_rewash_entry_id is not null then
    update public.finish_rewash_entries set status='SUPERSEDED' where finish_rewash_entry_id=v_existing.finish_rewash_entry_id;
  end if;
  insert into public.finish_rewash_entries(
    finish_rewash_entry_id,entry_group_id,revision_no,status,supersedes_finish_rewash_entry_id,production_business_date,
    shift_id,shift_code_snapshot,station_id,table_code_snapshot,table_name_snapshot,processed_by_staff_id,processed_by_name_snapshot,
    notes,recorded_by_staff_id,recorded_by_auth_user_id
  ) values (
    v_entry_id,v_group_id,case when v_existing.finish_rewash_entry_id is null then 1 else v_existing.revision_no+1 end,'ACTIVE',v_existing.finish_rewash_entry_id,v_business_date,
    v_shift.shift_id,v_shift.shift_code,v_station.station_id,v_station.station_code,v_station.station_name,v_processor.staff_id,v_processor.display_name,
    nullif(trim(p_notes),''),v_actor,auth.uid()
  ) returning * into v_saved;
  insert into public.finish_rewash_lines(
    finish_rewash_entry_id,line_no,customer_id,customer_code_snapshot,customer_name_snapshot,service_codes_snapshot,scheduled_days_snapshot,batch_reference,quantity_kg
  ) select
    v_saved.finish_rewash_entry_id,(item->>'line_no')::integer,(item->>'customer_id')::uuid,item->>'customer_code',item->>'customer_name',
    array(select jsonb_array_elements_text(item->'service_codes')),array(select jsonb_array_elements_text(item->'scheduled_days')),
    nullif(item->>'batch_reference',''),(item->>'quantity_kg')::numeric
  from jsonb_array_elements(v_clean) item;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_existing.finish_rewash_entry_id is null then 'RECORD_FINISH_REWASH' else 'CORRECT_FINISH_REWASH' end,
    'finish_rewash_entries',v_saved.finish_rewash_entry_id::text,v_before,jsonb_build_object('entry',to_jsonb(v_saved),'lines',v_clean),nullif(trim(p_notes),''),'FINISH_REWASH');

  return jsonb_build_object('status',case when v_existing.finish_rewash_entry_id is null then 'saved' else 'corrected' end,
    'finish_rewash_entry_id',v_saved.finish_rewash_entry_id,'entry_group_id',v_group_id,'revision_no',v_saved.revision_no,'processed_kg',v_total_kg);
end;
$function$;

-- record_sorting_trolley_intake_v2(p_shift_code text, p_trolley_code text, p_operator_staff_id uuid, p_customer_id uuid, p_contents_status text, p_scheduled_for_date date, p_product_codes text[], p_customer_override_reason text, p_off_schedule_reason text, p_notes text)
CREATE OR REPLACE FUNCTION public.record_sorting_trolley_intake_v2(p_shift_code text, p_trolley_code text, p_operator_staff_id uuid, p_customer_id uuid, p_contents_status text, p_scheduled_for_date date, p_product_codes text[], p_customer_override_reason text DEFAULT NULL::text, p_off_schedule_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_code text := upper(trim(coalesce(p_trolley_code,'')));
  v_contents text := upper(trim(coalesce(p_contents_status,'')));
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_trolley public.trolleys%rowtype;
  v_customer public.customers%rowtype;
  v_suggestion record;
  v_confirmation_source text := 'MANUAL_SELECTION';
  v_customer_override_reason text := nullif(trim(coalesce(p_customer_override_reason,'')),'');
  v_off_schedule_reason text := nullif(trim(coalesce(p_off_schedule_reason,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_products text[];
  v_product text;
  v_product_scope text;
  v_relation text;
  v_receipt jsonb;
  v_stay_id uuid;
  v_intake public.sorting_trolley_intakes%rowtype;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_schedule_product_id uuid;
  v_production_order integer;
  v_planned_trolley_quantity integer;
  v_route_id uuid;
  v_route_code text;
  v_route_display_name text;
  v_route_color text;
  v_flow_id uuid;
  v_child_id uuid;
  v_actor_staff_id uuid := public.current_staff_id();
  v_attendance_inserted integer := 0;
  v_product_payload jsonb := '[]'::jsonb;
  v_tracked_stay_id uuid;
  v_tracked_customer_id uuid;
  v_tracked_customer_name text;
  v_tracked_sent_on date;
  v_tracked_days integer;
  v_custody_tracking_status text := 'MISSING_OUTBOUND_RECORD';
  v_customer_override_code text;
  v_off_schedule_code text;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  if v_code='' then
    raise exception using errcode='22023', message='Trolley code is required.';
  end if;

  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Select your name before receiving the trolley.';
  end if;

  if p_customer_id is null then
    raise exception using errcode='22023', message='Confirmed customer is required.';
  end if;

  if v_contents not in ('CONTENTS','EMPTY') then
    raise exception using errcode='22023', message='Choose Laundry inside or Empty trolley.';
  end if;

  if exists(
    select 1
    from unnest(coalesce(p_product_codes,array[]::text[])) x
    where upper(trim(x)) not in ('CLOTHES','MOP')
  ) then
    raise exception using errcode='22023', message='Product selection contains an invalid value.';
  end if;

  select array_agg(distinct upper(trim(x)) order by upper(trim(x)))
  into v_products
  from unnest(coalesce(p_product_codes,array[]::text[])) x
  where upper(trim(x)) in ('CLOTHES','MOP');

  if coalesce(array_length(v_products,1),0)=0
     or array_length(v_products,1)>2 then
    raise exception using errcode='22023', message='Choose Clothes, MOP or Both.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='Trolley intake notes must be 1000 characters or fewer.';
  end if;

  if v_customer_override_reason is not null and length(v_customer_override_reason)>500 then
    raise exception using errcode='22023', message='Customer override reason must be 500 characters or fewer.';
  end if;

  if v_off_schedule_reason is not null and length(v_off_schedule_reason)>500 then
    raise exception using errcode='22023', message='Off-schedule reason must be 500 characters or fewer.';
  end if;

  v_customer_override_code := case upper(coalesce(v_customer_override_reason,''))
    when 'TROLLEY_CHANGED_BEFORE_SCAN' then 'TROLLEY_CHANGED_BEFORE_SCAN'
    when 'CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT' then 'CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT'
    when 'OTHER' then 'OTHER'
    when '' then null
    else 'OTHER'
  end;

  v_off_schedule_code := case upper(coalesce(v_off_schedule_reason,''))
    when 'SPECIAL_PRODUCTION' then 'SPECIAL_PRODUCTION'
    when 'SCHEDULE_DATA_ISSUE' then 'SCHEDULE_DATA_ISSUE'
    when 'NOT_ON_PUBLISHED_SCHEDULE' then 'NOT_ON_PUBLISHED_SCHEDULE'
    when 'OTHER' then 'OTHER'
    when '' then null
    else 'OTHER'
  end;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code=v_shift_code
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  -- Operator must be an Actual/Planned Sorting staff candidate for the shift.
  if not exists (
    select 1
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift_code)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id'=p_operator_staff_id::text
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is not active in Sorting for this shift.';
  end if;

  if exists (
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
      and a.attendance_status='ABSENT'
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is marked absent. Correct attendance before receiving a trolley.';
  end if;

  select *
  into v_trolley
  from public.trolleys t
  where lower(t.trolley_code)=lower(v_code)
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode='P0002', message=format('Trolley not found: %s',v_code);
  end if;

  if v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    raise exception using
      errcode='23514',
      message=format('Trolley %s cannot be received while status is %s.',v_code,v_trolley.status);
  end if;

  if exists (
    select 1
    from public.sorting_trolley_intakes sti
    where sti.trolley_id=v_trolley.trolley_id
      and sti.created_at>=now()-interval '10 minutes'
  ) then
    raise exception using
      errcode='23505',
      message=format('Trolley %s was already received a few minutes ago.',v_code);
  end if;

  select *
  into v_customer
  from public.customers c
  where c.customer_id=p_customer_id
    and c.active=true
    and c.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='22023', message='Confirmed customer is not active.';
  end if;

  select *
  into v_suggestion
  from public.suggest_trolley_customer(v_code);

  if v_suggestion.open_stay_id is not null then
    v_confirmation_source := 'OPEN_STAY';
  elsif v_suggestion.suggested_customer_id=p_customer_id
        and coalesce(v_suggestion.suggestion_reason,'')='LAST_KNOWN_CUSTOMER' then
    v_confirmation_source := 'LAST_KNOWN_CUSTOMER';
  else
    v_confirmation_source := 'MANUAL_SELECTION';
  end if;

  if v_suggestion.suggested_customer_id is not null
     and v_suggestion.suggested_customer_id is distinct from p_customer_id
     and v_customer_override_reason is null then
    raise exception using
      errcode='22023',
      message='Customer differs from trolley history. Enter the reason before confirming.';
  end if;

  if p_scheduled_for_date is null then
    if v_off_schedule_reason is null then
      raise exception using
        errcode='22023',
        message='Off-schedule trolley intake requires a reason.';
    end if;
    v_relation := 'OFF_SCHEDULE';
  else
    if p_scheduled_for_date < v_business_date-1 then
      raise exception using
        errcode='22023',
        message='Scheduled Date cannot be earlier than yesterday for Sorting Intake.';
    end if;

    if p_scheduled_for_date > v_business_date+7 then
      raise exception using
        errcode='22023',
        message='Scheduled Date must be within the next 7 scheduled days for Sorting Intake.';
    end if;

    v_relation := case
      when p_scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      when p_scheduled_for_date=v_business_date then 'TODAY'
      when p_scheduled_for_date=v_business_date+1 then 'TOMORROW'
      else 'FUTURE'
    end;
    v_off_schedule_reason := null;
  end if;

  -- Validate every selected product before closing physical custody.
  foreach v_product in array v_products loop
    if p_scheduled_for_date is not null then
      perform 1
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id=csv.schedule_version_id
       and sd.active=true
       and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id=sd.schedule_day_id
       and sp.active=true
      join public.product_types pt
        on pt.product_type_id=sp.product_type_id
       and pt.active=true
       and pt.deleted_at is null
      where csv.customer_id=p_customer_id
        and csv.status='PUBLISHED'
        and csv.effective_from<=p_scheduled_for_date
        and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
        and pt.product_code=v_product;

      if not found then
        raise exception using
          errcode='22023',
          message=format(
            '%s is not published for %s on %s. Choose the correct Scheduled Date or use Off schedule with a reason.',
            v_product,v_customer.customer_name,p_scheduled_for_date
          );
      end if;
    end if;
  end loop;

  -- Snapshot the tracked physical stay BEFORE receipt closes it.
  -- This is deliberately separate from the customer/content confirmation.
  select
    s.stay_id,
    s.outbound_customer_id,
    c.customer_name,
    s.sent_on,
    case
      when s.sent_on is null or current_date < s.sent_on then null
      else current_date - s.sent_on
    end
  into
    v_tracked_stay_id,
    v_tracked_customer_id,
    v_tracked_customer_name,
    v_tracked_sent_on,
    v_tracked_days
  from public.trolley_customer_stays s
  left join public.customers c
    on c.customer_id=s.outbound_customer_id
  where s.trolley_id=v_trolley.trolley_id
    and s.received_on is null
  order by s.created_at desc
  limit 1;

  v_custody_tracking_status := case
    when v_tracked_stay_id is null then 'MISSING_OUTBOUND_RECORD'
    when v_tracked_customer_id is distinct from p_customer_id then 'TRACKED_CUSTOMER_MISMATCH'
    else 'TRACKED_MATCH'
  end;

  -- Physical custody uses the actual calendar day. Operational grouping is
  -- preserved separately in sorting_trolley_intakes.business_date.
  v_receipt := public.confirm_trolley_sorting_arrival(
    p_trolley_code=>v_code,
    p_customer_id=>p_customer_id,
    p_arrived_on=>current_date,
    p_confirmation_source=>v_confirmation_source,
    p_notes=>v_notes
  );

  v_stay_id := nullif(v_receipt->>'stay_id','')::uuid;

  if v_stay_id is null then
    raise exception using errcode='P0001', message='Trolley lifecycle receipt did not return a stay ID.';
  end if;

  v_product_scope := case
    when array_length(v_products,1)=2 then 'BOTH'
    else v_products[1]
  end;

  insert into public.sorting_trolley_intakes(
    stay_id,trolley_id,trolley_code_snapshot,
    customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,physical_received_on,shift_id,shift_code_snapshot,arrived_at,
    contents_status,product_scope,scheduled_for_date,schedule_relation,
    confirmation_source,suggestion_reason,suggested_customer_id,
    customer_override_reason,off_schedule_reason,
    customer_override_code,off_schedule_code,
    tracked_outbound_customer_id,tracked_outbound_customer_name_snapshot,
    tracked_sent_on,tracked_days_at_customer,custody_tracking_status,
    exception_type,review_status,
    operator_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,
    notes
  )
  values(
    v_stay_id,v_trolley.trolley_id,v_code,
    v_customer.customer_id,v_customer.customer_code,v_customer.customer_name,
    v_business_date,current_date,v_shift.shift_id,v_shift_code,now(),
    v_contents,v_product_scope,p_scheduled_for_date,v_relation,
    v_confirmation_source,v_suggestion.suggestion_reason,v_suggestion.suggested_customer_id,
    v_customer_override_reason,v_off_schedule_reason,
    v_customer_override_code,v_off_schedule_code,
    v_tracked_customer_id,v_tracked_customer_name,
    v_tracked_sent_on,v_tracked_days,v_custody_tracking_status,
    nullif(v_receipt->>'exception_type',''),coalesce(v_receipt->>'review_status','NOT_REQUIRED'),
    p_operator_staff_id,v_actor_staff_id,auth.uid(),
    v_notes
  )
  returning * into v_intake;

  foreach v_product in array v_products loop
    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_schedule_product_id := null;
    v_production_order := null;
    v_planned_trolley_quantity := null;
    v_route_id := null;
    v_route_code := null;
    v_route_display_name := null;
    v_route_color := null;

    if p_scheduled_for_date is not null then
      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.schedule_product_id,
        sp.production_order,
        coalesce((
          select sum(req.quantity)::integer
          from public.customer_schedule_trolley_requirements req
          where req.schedule_day_id=sd.schedule_day_id
            and req.owner_schedule_product_id=sp.schedule_product_id
            and req.active=true
        ),0) as planned_trolley_quantity,
        r.route_id,
        r.route_code,
        r.display_name as route_display_name,
        r.route_color
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_schedule_product_id,
        v_production_order,
        v_planned_trolley_quantity,
        v_route_id,
        v_route_code,
        v_route_display_name,
        v_route_color
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id=csv.schedule_version_id
       and sd.active=true
       and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id=sd.schedule_day_id
       and sp.active=true
      join public.product_types pt
        on pt.product_type_id=sp.product_type_id
       and pt.active=true
       and pt.deleted_at is null
       and pt.product_code=v_product
      left join public.distribution_routes r
        on r.route_id=sd.default_route_id
       and r.deleted_at is null
      where csv.customer_id=p_customer_id
        and csv.status='PUBLISHED'
        and csv.effective_from<=p_scheduled_for_date
        and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
      order by csv.effective_from desc,csv.version_number desc
      limit 1;
    end if;

    v_flow_id := public.ensure_production_flow_item(
      p_customer_id,
      v_product,
      p_scheduled_for_date,
      v_business_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color
    );

    insert into public.sorting_trolley_intake_products(
      sorting_trolley_intake_id,
      product_code,
      scheduled_for_date,
      source_schedule_version_id,
      source_schedule_day_id,
      source_schedule_product_id,
      production_order_snapshot,
      planned_trolley_quantity_snapshot,
      route_id_snapshot,
      route_code_snapshot,
      route_display_name_snapshot,
      route_color_snapshot,
      production_flow_item_id
    )
    values(
      v_intake.sorting_trolley_intake_id,
      v_product,
      p_scheduled_for_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_planned_trolley_quantity,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color,
      v_flow_id
    )
    returning sorting_trolley_intake_product_id into v_child_id;

    perform public.append_production_flow_event(
      v_flow_id,
      case when v_contents='CONTENTS' then 'TROLLEY_RECEIVED_CONTENTS' else 'TROLLEY_RECEIVED_EMPTY' end,
      'INTAKE',
      20,
      'SORTING',
      v_business_date,
      v_intake.arrived_at,
      p_operator_staff_id,
      v_actor_staff_id,
      auth.uid(),
      'SORTING_V2',
      'sorting_trolley_intake_products',
      v_child_id::text,
      jsonb_build_object(
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
        'stay_id',v_stay_id,
        'trolley_id',v_trolley.trolley_id,
        'trolley_code',v_code,
        'customer_id',p_customer_id,
        'customer_name',v_customer.customer_name,
        'contents_status',v_contents,
        'product_code',v_product,
        'scheduled_for_date',p_scheduled_for_date,
        'schedule_relation',v_relation,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code,
        'review_status',v_intake.review_status,
        'exception_type',v_intake.exception_type,
        'physical_received_on',current_date,
        'custody_tracking_status',v_custody_tracking_status,
        'tracked_outbound_customer_id',v_tracked_customer_id,
        'tracked_outbound_customer_name',v_tracked_customer_name,
        'tracked_sent_on',v_tracked_sent_on,
        'tracked_days_at_customer',v_tracked_days,
        'customer_override_code',v_customer_override_code,
        'off_schedule_code',v_off_schedule_code,
        'trolley_status_after_receipt','AVAILABLE'
      )
    );

    v_product_payload := v_product_payload || jsonb_build_array(
      jsonb_build_object(
        'product_code',v_product,
        'production_flow_item_id',v_flow_id,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code
      )
    );
  end loop;

  insert into public.trolley_events(
    trolley_id,stay_id,event_type,customer_id,business_date,
    performed_by,source_application,reason,metadata
  )
  values(
    v_trolley.trolley_id,
    v_stay_id,
    case when v_contents='CONTENTS'
      then 'SORTING_CONTENTS_CONFIRMED'
      else 'SORTING_EMPTY_CONFIRMED'
    end,
    p_customer_id,
    v_business_date,
    p_operator_staff_id,
    'SORTING_V2',
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    jsonb_build_object(
      'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
      'contents_status',v_contents,
      'product_scope',v_product_scope,
      'product_codes',to_jsonb(v_products),
      'scheduled_for_date',p_scheduled_for_date,
      'schedule_relation',v_relation,
      'physical_received_on',current_date,
      'recorded_by_staff_id',v_actor_staff_id,
      'custody_tracking_status',v_custody_tracking_status,
      'tracked_outbound_customer_id',v_tracked_customer_id,
      'tracked_outbound_customer_name',v_tracked_customer_name,
      'tracked_sent_on',v_tracked_sent_on,
      'tracked_days_at_customer',v_tracked_days,
      'customer_override_code',v_customer_override_code,
      'off_schedule_code',v_off_schedule_code,
      'trolley_status_after_receipt','AVAILABLE'
    )
  );

  -- Trolley Intake is real presence evidence. Do not leave a staff member as
  -- inferred AUTO_ABSENT after they physically record an intake.
  insert into public.sorting_daily_staff_attendance(
    business_date,shift_id,staff_id,
    attendance_status,absence_reason,notes,source,
    created_by_auth_user_id,updated_by_auth_user_id
  )
  select
    v_business_date,v_shift.shift_id,p_operator_staff_id,
    'PRESENT',null,
    'Presence evidence from Sorting Trolley Intake ' || v_code || '.',
    'SORTING_TROLLEY_INTAKE',
    auth.uid(),auth.uid()
  where not exists(
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
  );

  get diagnostics v_attendance_inserted = row_count;

  if v_attendance_inserted>0 then
    insert into public.audit_log(
      actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
      new_data,reason,source_application
    )
    values(
      auth.uid(),v_actor_staff_id,
      'SORTING_ATTENDANCE_EVIDENCE_TROLLEY_INTAKE',
      'sorting_daily_staff_attendance',
      p_operator_staff_id::text || ':' || v_business_date::text || ':' || v_shift.shift_id::text,
      jsonb_build_object(
        'business_date',v_business_date,
        'shift_code',v_shift_code,
        'staff_id',p_operator_staff_id,
        'evidence','TROLLEY_INTAKE',
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id
      ),
      'Physical trolley intake recorded.',
      'SORTING_V2'
    );
  end if;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    new_data,reason,source_application
  )
  values(
    auth.uid(),v_actor_staff_id,
    case when v_contents='CONTENTS'
      then 'SORTING_TROLLEY_CONTENTS_INTAKE_RECORDED'
      else 'SORTING_TROLLEY_EMPTY_INTAKE_RECORDED'
    end,
    'sorting_trolley_intakes',
    v_intake.sorting_trolley_intake_id::text,
    to_jsonb(v_intake) || jsonb_build_object('products',v_product_payload),
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status','success',
    'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
    'stay_id',v_stay_id,
    'trolley_code',v_code,
    'customer_id',p_customer_id,
    'customer_name',v_customer.customer_name,
    'business_date',v_business_date,
    'physical_received_on',current_date,
    'contents_status',v_contents,
    'product_scope',v_product_scope,
    'scheduled_for_date',p_scheduled_for_date,
    'schedule_relation',v_relation,
    'review_status',v_intake.review_status,
    'products',v_product_payload,
    'custody_tracking_status',v_custody_tracking_status,
    'tracked_outbound_customer_id',v_tracked_customer_id,
    'tracked_outbound_customer_name',v_tracked_customer_name,
    'tracked_sent_on',v_tracked_sent_on,
    'tracked_days_at_customer',v_tracked_days,
    'trolley_status_after_receipt','AVAILABLE',
    'message',case
      when v_intake.review_status in ('PENDING','UNDER_REVIEW')
        then format('%s received. Trolley history needs review.',v_code)
      when v_contents='EMPTY'
        then format('%s received empty. No wash record was created.',v_code)
      else format('%s received with laundry. Customer is now visible in the wash queue.',v_code)
    end
  );
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
  if not public.has_any_role(array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR']) then
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
  if not public.has_any_role(array['ADMIN','MANAGER','PLANNER','ROSTER_MANAGER','DISTRIBUTION_OPERATOR','AUDITOR']) then
    raise exception 'You do not have access to Distribution Roster.' using errcode='42501';
  end if;
end;
$function$;

-- resolve_finish_delivery_reconciliation_v2(p_production_flow_item_id uuid, p_outcome_code text, p_approximate_processed_on date, p_approximate_processed_quantity numeric, p_approximate_processed_unit text, p_batch_reference text, p_notes text)
CREATE OR REPLACE FUNCTION public.resolve_finish_delivery_reconciliation_v2(p_production_flow_item_id uuid, p_outcome_code text, p_approximate_processed_on date DEFAULT NULL::date, p_approximate_processed_quantity numeric DEFAULT NULL::numeric, p_approximate_processed_unit text DEFAULT NULL::text, p_batch_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_now timestamptz:=now();
  v_local_date date:=(now() at time zone 'Europe/Dublin')::date;
  v_outcome text:=upper(trim(coalesce(p_outcome_code,'')));
  v_unit text:=upper(trim(coalesce(p_approximate_processed_unit,'')));
  v_flow public.production_flow_items%rowtype;
  v_delivery_date date;
  v_before jsonb;
  v_record public.finish_delivery_reconciliations%rowtype;
  v_batch text:=nullif(trim(coalesce(p_batch_reference,'')), '');
  v_notes text:=nullif(trim(coalesce(p_notes,'')), '');
  v_kg numeric(12,2);
begin
  perform public.require_finish_production_access();

  if p_production_flow_item_id is null then
    raise exception using errcode='22023',message='A Finish customer is required.';
  end if;
  if v_outcome not in ('PROCESSED_CONFIRMED','NOT_PROCESSED') then
    raise exception using errcode='22023',message='Choose whether the customer was processed.';
  end if;

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id
  for update;
  if not found or v_flow.product_code<>'CLOTHES' then
    raise exception using errcode='22023',message='This Finish reconciliation customer was not found.';
  end if;

  v_delivery_date:=public.next_distribution_business_date(v_flow.scheduled_for_date);
  if v_delivery_date>v_local_date or v_now<public.finish_delivery_cutoff(v_delivery_date) then
    raise exception using errcode='22023',message='Finish reconciliation is available only after 12:00 on the Delivery Date.';
  end if;
  if coalesce(v_flow.washed_trace_count,0)<=0 then
    raise exception using errcode='22023',message='Only a washed customer can be reconciled for Finish.';
  end if;
  if exists (
    select 1
    from public.finish_production_entries entry
    join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
    where entry.production_flow_item_id=v_flow.production_flow_item_id
      and entry.status='ACTIVE'
      and line.quantity>0
  ) then
    raise exception using errcode='22023',message='Finish production is already recorded for this customer.';
  end if;

  if v_outcome='PROCESSED_CONFIRMED' then
    if p_approximate_processed_on is null or p_approximate_processed_on>v_local_date then
      raise exception using errcode='22023',message='Enter an approximate processing date no later than today.';
    end if;
    if p_approximate_processed_quantity is null or p_approximate_processed_quantity<=0 then
      raise exception using errcode='22023',message='Enter an approximate processed quantity greater than zero.';
    end if;
    if v_unit not in ('KG','UNIT') then
      raise exception using errcode='22023',message='Choose KG or Units for the approximate processed quantity.';
    end if;
    v_kg:=case when v_unit='KG' then p_approximate_processed_quantity else null end;
  else
    p_approximate_processed_on:=null;
    p_approximate_processed_quantity:=null;
    v_unit:=null;
    v_kg:=null;
    v_batch:=null;
  end if;

  select to_jsonb(rec) into v_before
  from public.finish_delivery_reconciliations rec
  where rec.production_flow_item_id=v_flow.production_flow_item_id;

  insert into public.finish_delivery_reconciliations(
    production_flow_item_id,delivery_date,outcome_code,approximate_processed_on,approximate_processed_kg,
    approximate_processed_quantity,approximate_processed_unit,batch_reference,notes,
    acknowledged_at,next_prompt_at,resolved_at,recorded_by_auth_user_id,recorded_by_staff_id,updated_at,updated_by_auth_user_id
  ) values (
    v_flow.production_flow_item_id,v_delivery_date,v_outcome,p_approximate_processed_on,v_kg,
    p_approximate_processed_quantity,v_unit,v_batch,v_notes,v_now,
    case when v_outcome='NOT_PROCESSED' then v_now+interval '2 hours' else null end,
    case when v_outcome='PROCESSED_CONFIRMED' then v_now else null end,
    auth.uid(),public.current_staff_id(),v_now,auth.uid()
  )
  on conflict (production_flow_item_id) do update set
    delivery_date=excluded.delivery_date,
    outcome_code=excluded.outcome_code,
    approximate_processed_on=excluded.approximate_processed_on,
    approximate_processed_kg=excluded.approximate_processed_kg,
    approximate_processed_quantity=excluded.approximate_processed_quantity,
    approximate_processed_unit=excluded.approximate_processed_unit,
    batch_reference=excluded.batch_reference,
    notes=excluded.notes,
    acknowledged_at=excluded.acknowledged_at,
    next_prompt_at=excluded.next_prompt_at,
    resolved_at=excluded.resolved_at,
    updated_at=excluded.updated_at,
    updated_by_auth_user_id=excluded.updated_by_auth_user_id
  returning * into v_record;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
  ) values (
    auth.uid(),public.current_staff_id(),
    case when v_outcome='PROCESSED_CONFIRMED' then 'FINISH_DELIVERY_PROCESSED_CONFIRMED' else 'FINISH_DELIVERY_NOT_PROCESSED_ACKNOWLEDGED' end,
    'finish_delivery_reconciliations',v_record.finish_delivery_reconciliation_id::text,
    v_before,to_jsonb(v_record),v_notes,'FINISH_DELIVERY_RECONCILIATION'
  );

  return jsonb_build_object(
    'finish_delivery_reconciliation_id',v_record.finish_delivery_reconciliation_id,
    'outcome_code',v_record.outcome_code,
    'next_prompt_at',v_record.next_prompt_at,
    'message',case when v_outcome='PROCESSED_CONFIRMED' then 'Approximate Finish processing was confirmed and the delivery check is closed.' else 'Not processed was acknowledged. This customer will block Finish again in two hours.' end
  );
end;
$function$;

-- save_distribution_roster_draft(p_week_start date, p_entries jsonb, p_notes text, p_change_reason text)
CREATE OR REPLACE FUNCTION public.save_distribution_roster_draft(p_week_start date, p_entries jsonb, p_notes text DEFAULT NULL::text, p_change_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_draft public.distribution_roster_versions%rowtype;
  v_base public.distribution_roster_versions%rowtype;
  v_next integer;
  j jsonb;
  v_driver public.distribution_drivers%rowtype;
  v_route public.distribution_routes%rowtype;
  v_vehicle public.fleet_vehicles%rowtype;
  v_date date;
  v_day_status text;
  v_assignment_status text;
  v_route_id uuid;
  v_vehicle_id uuid;
  v_block text;
  v_route_code text;
  v_route_name text;
  v_route_color text;
  v_vehicle_registration text;
  v_vehicle_name text;
begin
  perform public.require_distribution_roster_manage_access();

  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'Week start must be a Monday.' using errcode='22023';
  end if;
  if jsonb_typeof(coalesce(p_entries,'[]'::jsonb)) <> 'array' then
    raise exception 'Entries must be a JSON array.' using errcode='22023';
  end if;

  select * into v_draft
  from public.distribution_roster_versions
  where week_start=p_week_start and roster_status='DRAFT'
  for update;

  if v_draft.distribution_roster_version_id is null then
    select * into v_base
    from public.distribution_roster_versions
    where week_start=p_week_start and roster_status='PUBLISHED'
    order by version_number desc
    limit 1;

    select coalesce(max(version_number),0)+1
      into v_next
    from public.distribution_roster_versions
    where week_start=p_week_start;

    insert into public.distribution_roster_versions(
      week_start,
      version_number,
      roster_status,
      roster_note,
      based_on_version_id,
      change_reason,
      created_by,
      updated_by
    ) values (
      p_week_start,
      v_next,
      'DRAFT',
      p_notes,
      v_base.distribution_roster_version_id,
      nullif(trim(p_change_reason),''),
      auth.uid(),
      auth.uid()
    ) returning * into v_draft;

    if to_regclass('public.distribution_roster_events') is not null then
      insert into public.distribution_roster_events(
        distribution_roster_version_id,event_type,event_payload,recorded_by
      ) values (
        v_draft.distribution_roster_version_id,
        'DRAFT_CREATED',
        jsonb_build_object('source','DISTRIBUTION_WEEKLY_ROSTER_V2'),
        auth.uid()
      );
    end if;
  else
    update public.distribution_roster_versions
    set roster_note=p_notes,
        change_reason=coalesce(nullif(trim(p_change_reason),''),change_reason),
        updated_by=auth.uid(),
        row_version=row_version+1
    where distribution_roster_version_id=v_draft.distribution_roster_version_id
    returning * into v_draft;
  end if;

  delete from public.distribution_roster_entries
  where distribution_roster_version_id=v_draft.distribution_roster_version_id;

  for j in
    select value
    from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb))
  loop
    v_date := nullif(j->>'work_date','')::date;
    v_day_status := upper(trim(coalesce(j->>'day_status','')));
    v_route_id := nullif(j->>'route_id','')::uuid;
    v_vehicle_id := nullif(j->>'vehicle_id','')::uuid;

    if v_date is null or v_date < p_week_start or v_date > p_week_start+6 then
      raise exception 'Roster date % is outside selected week.',v_date using errcode='22023';
    end if;

    if v_day_status not in ('WORKING','OFF','HOLIDAY','TRAINING','ABSENT') then
      raise exception 'Unsupported Distribution roster status: %',v_day_status using errcode='22023';
    end if;

    select * into v_driver
    from public.distribution_drivers
    where driver_id=nullif(j->>'driver_id','')::uuid
      and deleted_at is null;

    if v_driver.driver_id is null then
      raise exception 'Driver not found.' using errcode='22023';
    end if;

    if v_driver.employment_status <> 'ACTIVE' then
      raise exception 'Driver % is not active.',v_driver.display_name using errcode='22023';
    end if;

    if exists (
      select 1
      from public.distribution_driver_absences a
      where a.driver_id=v_driver.driver_id
        and a.absence_status='APPROVED'
        and v_date between a.starts_on and a.ends_on
    ) and v_day_status='WORKING' then
      raise exception 'Driver % has approved leave/absence on %.',v_driver.display_name,v_date using errcode='22023';
    end if;

    if v_day_status='WORKING' and v_driver.availability_status <> 'AVAILABLE' then
      raise exception 'Driver % is not available for working assignment.',v_driver.display_name using errcode='22023';
    end if;

    if v_day_status='WORKING' then
      v_assignment_status := 'PLANNED';

      if v_route_id is null or v_vehicle_id is null then
        raise exception 'Working assignment requires both route and vehicle.' using errcode='22023';
      end if;

      if not public.distribution_route_valid_on_date(v_route_id,v_date) then
        raise exception 'Selected route is not available for %.',v_date using errcode='22023';
      end if;

      select * into v_route
      from public.distribution_routes
      where route_id=v_route_id
        and active
        and deleted_at is null;

      if v_route.route_id is null then
        raise exception 'Selected route is inactive or invalid.' using errcode='22023';
      end if;

      select * into v_vehicle
      from public.fleet_vehicles
      where vehicle_id=v_vehicle_id
        and deleted_at is null;

      if v_vehicle.vehicle_id is null then
        raise exception 'Selected vehicle was not found.' using errcode='22023';
      end if;

      v_block := public.distribution_vehicle_block_reason(v_vehicle_id,v_date);
      if v_block is not null then
        raise exception 'Vehicle % cannot be assigned on %: %',
          coalesce(v_vehicle.registration_number,v_vehicle_id::text),v_date,v_block
          using errcode='22023';
      end if;

      v_route_code := v_route.route_code;
      v_route_name := v_route.display_name;
      v_route_color := v_route.route_color;
      v_vehicle_registration := v_vehicle.registration_number;
      v_vehicle_name := v_vehicle.display_name;
    else
      v_assignment_status := v_day_status;
      v_route_id := null;
      v_vehicle_id := null;
      v_route_code := null;
      v_route_name := null;
      v_route_color := null;
      v_vehicle_registration := null;
      v_vehicle_name := null;
    end if;

    insert into public.distribution_roster_entries(
      distribution_roster_version_id,
      work_date,
      route_id,
      assignment_status,
      primary_driver_id,
      support_driver_id,
      vehicle_id,
      route_code_snapshot,
      route_name_snapshot,
      route_color_snapshot,
      primary_driver_name_snapshot,
      support_driver_name_snapshot,
      vehicle_registration_snapshot,
      vehicle_name_snapshot,
      entry_note,
      created_by,
      updated_by
    ) values (
      v_draft.distribution_roster_version_id,
      v_date,
      v_route_id,
      v_assignment_status,
      v_driver.driver_id,
      null,
      v_vehicle_id,
      v_route_code,
      v_route_name,
      v_route_color,
      v_driver.display_name,
      null,
      v_vehicle_registration,
      v_vehicle_name,
      nullif(j->>'notes',''),
      auth.uid(),
      auth.uid()
    );
  end loop;

  if to_regclass('public.distribution_roster_events') is not null then
    insert into public.distribution_roster_events(
      distribution_roster_version_id,event_type,event_payload,recorded_by
    ) values (
      v_draft.distribution_roster_version_id,
      'DRAFT_SAVED',
      jsonb_build_object(
        'entry_count',jsonb_array_length(coalesce(p_entries,'[]'::jsonb)),
        'source','DISTRIBUTION_WEEKLY_ROSTER_V2'
      ),
      auth.uid()
    );
  end if;

  return public.get_distribution_roster_context(p_week_start);
exception
  when unique_violation then
    raise exception 'A driver, route or vehicle is already assigned to another record on the same day.' using errcode='23505';
end;
$function$;

-- set_sorting_staff_actual_area(p_shift_code text, p_staff_id uuid, p_target_area_code text, p_notes text)
CREATE OR REPLACE FUNCTION public.set_sorting_staff_actual_area(p_shift_code text, p_staff_id uuid, p_target_area_code text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$ declare v_shift_code text := upper(trim(coalesce(p_shift_code, ''))); v_target_code text := upper(trim(coalesce(p_target_area_code, ''))); v_notes text := nullif(trim(coalesce(p_notes, '')), ''); v_business_date date := public.operational_business_date_for_shift(p_shift_code); v_shift public.shifts%rowtype; v_target_area public.areas%rowtype; v_sorting_area_id uuid; v_target jsonb; v_context jsonb; v_staff_name text; v_session public.work_sessions%rowtype; v_old_data jsonb; v_new public.work_sessions%rowtype; v_roster_entry_id uuid; v_roster_version_id uuid; v_break_minutes integer := 0; v_actor_staff_id uuid; begin perform public.require_sorting_operational_access(); if p_staff_id is null then raise exception using errcode = '22023', message = 'Staff is required.'; end if; if v_target_code = '' or v_target_code = 'SORTING' then raise exception using errcode = '22023', message = 'Choose another operational area.'; end if; if v_notes is not null and length(v_notes) > 1000 then raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.'; end if; select * into v_shift from public.shifts sh where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null limit 1; if not found then raise exception using errcode = 'P0002', message = 'Selected shift is not available.'; end if; select * into v_target_area from public.areas a where a.area_code = v_target_code and a.active = true and a.deleted_at is null and a.area_code in ('FINISH','MOP','WASHING','DISTRIBUTION') limit 1; if not found then raise exception using errcode = '22023', message = 'Selected destination area is not available for an Actual transfer.'; end if; select a.area_id into v_sorting_area_id from public.areas a where a.area_code = 'SORTING' and a.active = true and a.deleted_at is null limit 1; v_context := public.get_sorting_staff_work_context_v2(v_shift_code); select value into v_target from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb)) where value ->> 'staff_id' = p_staff_id::text limit 1; if v_target is null then raise exception using errcode = '22023', message = 'The selected staff member is not currently shown in Sorting for this shift.'; end if; v_staff_name := coalesce(v_target ->> 'display_name', 'Selected staff member'); v_roster_entry_id := nullif(v_target ->> 'roster_entry_id', '')::uuid; v_roster_version_id := nullif(v_target ->> 'roster_version_id', '')::uuid; v_break_minutes := coalesce(nullif(v_target ->> 'standard_break_minutes', '')::integer, 0); v_actor_staff_id := public.current_staff_id(); if exists ( select 1 from public.sorting_daily_staff_attendance att where att.business_date = v_business_date and att.shift_id = v_shift.shift_id and att.staff_id = p_staff_id and att.attendance_status = 'ABSENT' ) then raise exception using errcode = '22023', message = format('%s is already recorded as not working in Sorting. Correct that status before moving the staff member to another area.', v_staff_name); end if; if exists ( select 1 from public.work_sessions ws where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id and ws.staff_id = p_staff_id and ws.source = 'SORTING_AREA_TRANSFER' and ws.status <> 'CANCELLED' ) then raise exception using errcode = '23505', message = format('%s already has an active Actual area transfer for this shift.', v_staff_name); end if; if exists ( select 1 from public.sorting_wash_runs wr where wr.business_date = v_business_date and wr.shift_id = v_shift.shift_id and wr.operator_staff_id = p_staff_id and wr.status = 'RECORDED' ) or exists ( select 1 from public.sorting_trolley_intakes sti where sti.business_date = v_business_date and sti.shift_id = v_shift.shift_id and sti.operator_staff_id = p_staff_id ) then raise exception using errcode = '22023', message = format('%s already has recorded Sorting activity for this Business Date and Shift. Correct that activity before replacing the whole-shift Sorting position.', v_staff_name); end if; if nullif(v_target ->> 'work_session_id', '') is not null then select * into v_session from public.work_sessions ws where ws.work_session_id = (v_target ->> 'work_session_id')::uuid and ws.status <> 'CANCELLED'; end if; if v_session.work_session_id is null and v_roster_entry_id is not null then select * into v_session from public.work_sessions ws where ws.production_roster_entry_id = v_roster_entry_id and ws.status <> 'CANCELLED' order by ws.updated_at desc limit 1; end if; if v_session.work_session_id is not null then v_old_data := to_jsonb(v_session); update public.work_sessions set area_id = v_target_area.area_id, station_id = null, source = 'SORTING_AREA_TRANSFER', notes = case when v_notes is null then notes else v_notes end, recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = now() where work_session_id = v_session.work_session_id returning * into v_new; else insert into public.work_sessions ( production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id, shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes, recorded_by_auth_user_id, row_version, updated_at ) values ( v_roster_entry_id, v_roster_version_id, v_business_date, p_staff_id, v_target_area.area_id, null, v_shift.shift_id, null, null, v_break_minutes, 0, 'NONE', 'OPEN', 'SORTING_AREA_TRANSFER', v_actor_staff_id, v_notes, auth.uid(), 1, now() ) returning * into v_new; end if; insert into public.audit_log ( actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application ) values ( auth.uid(), v_actor_staff_id, 'SORTING_ACTUAL_AREA_TRANSFERRED', 'work_sessions', v_new.work_session_id::text, v_old_data, to_jsonb(v_new), concat('Actual position moved from Sorting Area to ', v_target_area.area_name, case when v_notes is null then '' else ': ' || v_notes end), 'SORTING_V2' ); return jsonb_build_object( 'status', 'success', 'business_date', v_business_date, 'shift_code', v_shift_code, 'staff_id', p_staff_id, 'staff_name', v_staff_name, 'work_session_id', v_new.work_session_id, 'actual_area_code', v_target_area.area_code, 'actual_area_name', v_target_area.area_name, 'roster_unchanged', true, 'audit_recorded', true, 'message', format('%s moved to %s for Actual staffing. The published Roster was not changed.', v_staff_name, v_target_area.area_name) ); end; $function$;

-- sorting_schedule_product_snapshot(p_customer_id uuid, p_product_code text, p_scheduled_for_date date)
CREATE OR REPLACE FUNCTION public.sorting_schedule_product_snapshot(p_customer_id uuid, p_product_code text, p_scheduled_for_date date)
 RETURNS TABLE(schedule_version_id uuid, schedule_day_id uuid, schedule_product_id uuid, production_order integer, planned_trolley_quantity integer, route_id uuid, route_code text, route_display_name text, route_color text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare v_product text := upper(trim(coalesce(p_product_code,'')));
begin
  if p_customer_id is null or p_scheduled_for_date is null or v_product not in ('CLOTHES','MOP') then raise exception using errcode='22023', message='Schedule product lookup is incomplete.'; end if;
  return query
  select csv.schedule_version_id, sd.schedule_day_id, sp.schedule_product_id, sp.production_order,
    coalesce((select sum(req.quantity)::integer from public.customer_schedule_trolley_requirements req where req.schedule_day_id=sd.schedule_day_id and req.owner_schedule_product_id=sp.schedule_product_id and req.active=true),0),
    r.route_id, r.route_code, r.display_name, r.route_color
  from public.customer_schedule_versions csv
  join public.customer_schedule_days sd on sd.schedule_version_id=csv.schedule_version_id and sd.active=true and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
  join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active=true
  join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active=true and pt.deleted_at is null and pt.product_code=v_product
  left join public.distribution_routes r on r.route_id=sd.default_route_id and r.deleted_at is null
  where csv.customer_id=p_customer_id and csv.status='PUBLISHED' and csv.effective_from<=p_scheduled_for_date and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
  order by csv.effective_from desc,csv.version_number desc limit 1;
  if not found then raise exception using errcode='22023', message='Selected customer/product is not published for the selected Scheduled Date.'; end if;
end; $function$;

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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']) then
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

do $$
declare
  v_fn regprocedure;
begin
  for v_fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (
        (p.proname = 'publish_distribution_roster'
          and pg_get_function_identity_arguments(p.oid) = 'p_week_start date, p_change_reason text')
        or p.proname in (
          'save_distribution_roster_draft',
          'get_distribution_roster_context',
          'get_distribution_roster_history',
          'require_distribution_roster_read_access',
          'require_distribution_roster_manage_access',
          'distribution_route_valid_on_date'
        )
      )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
  end loop;
end;
$$;

commit;
