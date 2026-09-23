-- ElisCaretex V2
-- Migration: 202608110013_sorting_mop_trace_abs_and_ui_compaction
-- Prepared: 2026-08-11
-- Status: PREPARED — OWNER MUST RUN
--
-- Purpose:
--   * connect the MOP Production trace to the shared Production Flow ABS batch model;
--   * allow a controlled Sorting workstation to post an ABS batch for an already
--     recorded MOP Production batch without creating a second ABS data store;
--   * expose a compact MOP trace read model including MOP lines, trolley evidence,
--     ABS status, batch number, posting staff and posting time;
--   * preserve the existing shared Finish/MOP external batch foundation.
--
-- Governance:
--   * direct browser access to production_flow_external_batches stays revoked;
--   * MOP Production may only post ABS after a RECORDED MOP production batch exists;
--   * the normal shared ABS API remains authoritative for the external batch record;
--   * Sorting access to the shared ABS write API is restricted to MOP flows that
--     already have recorded MOP Production evidence;
--   * this migration does not alter or delete historical MOP production records.

begin;

-- ---------------------------------------------------------------------
-- 1. Flow-aware ABS write authorization.
-- ---------------------------------------------------------------------

create or replace function public.require_production_flow_abs_batch_write_access(
  p_production_flow_item_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_product_code text;
  v_has_mop_production boolean := false;
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using
      errcode='42501',
      message='An authenticated staff profile is required for ABS production batch entry.';
  end if;

  select pfi.product_code
  into v_product_code
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;

  if not found then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  if public.has_any_role(array[
    'ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR'
  ]) then
    return;
  end if;

  if public.has_any_role(array['SORTING_OPERATOR'])
     and v_product_code='MOP' then
    select exists(
      select 1
      from public.sorting_mop_production_batches mb
      where mb.production_flow_item_id=p_production_flow_item_id
        and mb.status='RECORDED'
    )
    into v_has_mop_production;

    if v_has_mop_production then
      return;
    end if;
  end if;

  raise exception using
    errcode='42501',
    message='Your active role does not allow ABS production batch entry for this Production Flow item.';
end;
$$;

revoke all on function public.require_production_flow_abs_batch_write_access(uuid)
  from public, anon, authenticated;

comment on function public.require_production_flow_abs_batch_write_access(uuid)
  is 'Private ABS authorization helper. Sorting operators are allowed only for MOP flows that already have a recorded MOP Production batch; Finish/MOP/management roles retain shared batch access.';

-- ---------------------------------------------------------------------
-- 2. Keep the existing shared ABS API, but make its authorization
--    flow-aware so MOP Production can reuse the same data model.
-- ---------------------------------------------------------------------

create or replace function public.record_production_flow_abs_batch(
  p_production_flow_item_id uuid,
  p_batch_reference text,
  p_quantity numeric,
  p_unit_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_staff_id uuid;
  v_batch public.production_flow_external_batches%rowtype;
  v_effective_quantity numeric := p_quantity;
  v_effective_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_sorting_constrained boolean := false;
  v_mop_total_kg numeric;
  v_mop_total_units integer;
begin
  perform public.require_production_flow_abs_batch_write_access(
    p_production_flow_item_id
  );

  if v_reference is null then
    raise exception using errcode='22023', message='ABS batch number is required.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='ABS batch notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  -- Authenticated users share one database role in the browser, so authorization
  -- cannot rely on GRANT alone. A staff member whose only applicable batch-write
  -- path is SORTING_OPERATOR must never be able to bypass the MOP wrapper by
  -- calling this shared function with a browser-supplied quantity. For that path
  -- the authoritative quantity/unit are derived again from RECORDED MOP Production.
  v_sorting_constrained :=
    public.has_any_role(array['SORTING_OPERATOR'])
    and not public.has_any_role(array[
      'ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR'
    ]);

  if v_sorting_constrained then
    if v_flow.product_code<>'MOP' then
      raise exception using
        errcode='42501',
        message='Sorting operators may post ABS only for recorded MOP Production.';
    end if;

    select mb.total_weight_kg, mb.total_units
    into v_mop_total_kg, v_mop_total_units
    from public.sorting_mop_production_batches mb
    where mb.production_flow_item_id=v_flow.production_flow_item_id
      and mb.status='RECORDED'
    order by mb.recorded_at desc, mb.mop_production_batch_id desc
    limit 1;

    if not found then
      raise exception using
        errcode='42501',
        message='Sorting ABS entry requires an already-recorded MOP Production batch.';
    end if;

    if coalesce(v_mop_total_kg,0)>0 then
      v_effective_quantity:=v_mop_total_kg;
      v_effective_unit:='KG';
    elsif coalesce(v_mop_total_units,0)>0 then
      v_effective_quantity:=v_mop_total_units;
      v_effective_unit:='UNIT';
    else
      raise exception using
        errcode='22023',
        message='Recorded MOP Production has no positive KG or Units for ABS batch entry.';
    end if;
  else
    v_effective_quantity:=p_quantity;
    v_effective_unit:=v_unit;
  end if;

  if v_effective_quantity is null or v_effective_quantity <= 0 then
    raise exception using errcode='22023', message='ABS batch quantity must be greater than zero.';
  end if;

  if v_effective_unit not in ('KG','UNIT') then
    raise exception using errcode='22023', message='ABS batch unit must be KG or UNIT.';
  end if;

  if v_effective_unit='UNIT' and v_effective_quantity <> trunc(v_effective_quantity) then
    raise exception using errcode='22023', message='ABS UNIT quantity must be a whole number.';
  end if;

  v_staff_id := public.current_staff_id();

  insert into public.production_flow_external_batches (
    production_flow_item_id,
    external_system_code,
    batch_reference,
    quantity,
    unit_code,
    capture_source,
    status,
    notes,
    recorded_by_staff_id,
    recorded_by_auth_user_id
  )
  values (
    v_flow.production_flow_item_id,
    'ABS',
    v_reference,
    v_effective_quantity,
    v_effective_unit,
    'MANUAL',
    'ACTIVE',
    v_notes,
    v_staff_id,
    auth.uid()
  )
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,
    'ABS_BATCH_RECORDED',
    'PRODUCTION',
    40,
    case when v_flow.product_code='MOP' then 'MOP' else 'FINISH' end,
    public.current_business_date(),
    v_batch.recorded_at,
    v_staff_id,
    v_staff_id,
    auth.uid(),
    'ELISCARETEXT_V2',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    jsonb_build_object(
      'external_system_code','ABS',
      'batch_reference',v_batch.batch_reference,
      'quantity',v_batch.quantity,
      'unit_code',v_batch.unit_code,
      'capture_source',v_batch.capture_source
    )
  );

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
    v_staff_id,
    'PRODUCTION_FLOW_ABS_BATCH_RECORDED',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    to_jsonb(v_batch),
    v_notes,
    'ELISCARETEXT_V2'
  );

  return jsonb_build_object(
    'status','success',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'flow_code',v_flow.flow_code,
    'external_batch_id',v_batch.production_flow_external_batch_id,
    'batch_reference',v_batch.batch_reference,
    'quantity',v_batch.quantity,
    'unit_code',v_batch.unit_code,
    'capture_source',v_batch.capture_source,
    'quantity_source',case when v_sorting_constrained then 'RECORDED_MOP_PRODUCTION' else 'CALLER_AUTHORIZED' end,
    'message',format(
      'ABS batch %s recorded manually for %s.',
      v_batch.batch_reference,
      v_flow.flow_code
    )
  );
end;
$$;

revoke all on function public.record_production_flow_abs_batch(uuid,text,numeric,text,text)
  from public, anon, authenticated;
grant execute on function public.record_production_flow_abs_batch(uuid,text,numeric,text,text)
  to authenticated;

comment on function public.record_production_flow_abs_batch(uuid,text,numeric,text,text)
  is 'Shared Production Flow ABS batch write API. Snapshot 93 keeps Finish/MOP roles and additionally permits Sorting operators only for MOP flows with recorded MOP Production evidence.';

-- ---------------------------------------------------------------------
-- 3. MOP Production convenience API.
--    Staff enter only the ABS batch number. Quantity is derived from the
--    already-recorded MOP Production evidence, never trusted from browser.
-- ---------------------------------------------------------------------

create or replace function public.record_sorting_mop_abs_batch(
  p_mop_production_batch_id uuid,
  p_batch_reference text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_mop_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_existing public.production_flow_external_batches%rowtype;
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_quantity numeric;
  v_unit_code text;
  v_result jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_reference is null then
    raise exception using errcode='22023', message='ABS batch number is required.';
  end if;

  if length(v_reference)>120 then
    raise exception using errcode='22023', message='ABS batch number must be 120 characters or fewer.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='ABS notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_mop_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002', message='Recorded MOP Production batch was not found.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_mop_batch.production_flow_item_id
  for update;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023', message='ABS posting from MOP Production requires an exact MOP Production Flow item.';
  end if;

  select b.*
  into v_existing
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_flow.production_flow_item_id
    and b.external_system_code='ABS'
    and b.status='ACTIVE'
  order by b.recorded_at desc,b.production_flow_external_batch_id desc
  limit 1;

  if found then
    if trim(v_existing.batch_reference)=v_reference then
      return jsonb_build_object(
        'status','success',
        'skipped',true,
        'production_flow_item_id',v_flow.production_flow_item_id,
        'mop_production_batch_id',v_mop_batch.mop_production_batch_id,
        'external_batch_id',v_existing.production_flow_external_batch_id,
        'batch_reference',v_existing.batch_reference,
        'quantity',v_existing.quantity,
        'unit_code',v_existing.unit_code,
        'message',format('ABS batch %s is already recorded for this MOP production.',v_existing.batch_reference)
      );
    end if;

    raise exception using
      errcode='23505',
      message=format(
        'This MOP production already has active ABS batch %s. Use the governed ABS correction workflow instead of adding a second batch.',
        v_existing.batch_reference
      );
  end if;

  if coalesce(v_mop_batch.total_weight_kg,0)>0 then
    v_quantity:=v_mop_batch.total_weight_kg;
    v_unit_code:='KG';
  elsif coalesce(v_mop_batch.total_units,0)>0 then
    v_quantity:=v_mop_batch.total_units;
    v_unit_code:='UNIT';
  else
    raise exception using
      errcode='22023',
      message='The recorded MOP Production has no positive KG or Units to anchor the ABS batch.';
  end if;

  v_result:=public.record_production_flow_abs_batch(
    v_flow.production_flow_item_id,
    v_reference,
    v_quantity,
    v_unit_code,
    v_notes
  );

  return v_result || jsonb_build_object(
    'mop_production_batch_id',v_mop_batch.mop_production_batch_id,
    'source_application','SORTING_MOP_PRODUCTION',
    'quantity_source',case when v_unit_code='KG' then 'MOP_PRODUCTION_TOTAL_KG' else 'MOP_PRODUCTION_TOTAL_UNITS' end
  );
end;
$$;

revoke all on function public.record_sorting_mop_abs_batch(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.record_sorting_mop_abs_batch(uuid,text,text)
  to authenticated;

comment on function public.record_sorting_mop_abs_batch(uuid,text,text)
  is 'Posts the ABS batch number from an already-recorded MOP Production batch. Quantity is derived server-side from recorded MOP KG, or Units only when KG is unavailable. Uses the shared Production Flow ABS store.';

-- ---------------------------------------------------------------------
-- 4. MOP trace read model.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_mop_recent_trace(
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb := '[]'::jsonb;
  v_pending integer := 0;
  v_posted integer := 0;
begin
  perform public.require_sorting_operational_access();

  with recent as (
    select mb.*
    from public.sorting_mop_production_batches mb
    where mb.status='RECORDED'
    order by mb.recorded_at desc,mb.mop_production_batch_id desc
    limit v_limit
  ), trace_rows as (
    select
      mb.mop_production_batch_id,
      mb.production_flow_item_id,
      mb.customer_id,
      mb.customer_name_snapshot as customer_name,
      mb.business_date,
      mb.scheduled_for_date,
      mb.delivery_due_date,
      mb.operator_staff_id,
      sm.display_name as operator_name,
      mb.entry_mode,
      mb.physical_processed_on,
      mb.physical_processed_time,
      mb.physical_time_precision,
      mb.total_weight_kg as total_kg,
      mb.total_units,
      mb.trolley_capture_status,
      mb.planned_output_trolley_quantity,
      mb.recorded_at,
      mb.notes,
      coalesce(lines.lines,'[]'::jsonb) as lines,
      coalesce(trolleys.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(abs_data.active_abs_batches,'[]'::jsonb) as active_abs_batches,
      coalesce(abs_data.abs_history_count,0)::integer as abs_history_count,
      case when coalesce(abs_data.active_abs_count,0)>0 then 'POSTED' else 'PENDING' end as abs_status
    from recent mb
    left join public.staff_members sm on sm.staff_id=mb.operator_staff_id
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',ml.product_variant_id,
        'variant_code',ml.variant_code_snapshot,
        'variant_name',ml.variant_name_snapshot,
        'weight_kg',ml.weight_kg,
        'units',ml.units,
        'unit_weight_grams',ml.unit_weight_grams_snapshot
      ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb) as lines
      from public.sorting_mop_production_lines ml
      where ml.mop_production_batch_id=mb.mop_production_batch_id
    ) lines on true
    left join lateral (
      select coalesce(jsonb_agg(mt.trolley_code_snapshot order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb) as trolley_codes
      from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=mb.mop_production_batch_id
    ) trolleys on true
    left join lateral (
      select
        count(*) filter(where b.status='ACTIVE')::integer as active_abs_count,
        count(*)::integer as abs_history_count,
        coalesce(jsonb_agg(jsonb_build_object(
          'external_batch_id',b.production_flow_external_batch_id,
          'batch_reference',b.batch_reference,
          'batch_number',b.batch_number,
          'batch_business_date',b.batch_business_date,
          'batch_week_start',b.batch_week_start,
          'quantity',b.quantity,
          'unit_code',b.unit_code,
          'capture_source',b.capture_source,
          'status',b.status,
          'recorded_at',b.recorded_at,
          'recorded_by_staff_id',b.recorded_by_staff_id,
          'recorded_by_name',abs_staff.display_name,
          'notes',b.notes,
          'supersedes_external_batch_id',b.supersedes_external_batch_id,
          'correction_reason',b.correction_reason,
          'cancelled_at',b.cancelled_at
        ) order by
          case b.status when 'ACTIVE' then 0 when 'SUPERSEDED' then 1 else 2 end,
          b.recorded_at desc,b.production_flow_external_batch_id desc
        ) filter(where b.status='ACTIVE'),'[]'::jsonb) as active_abs_batches
      from public.production_flow_external_batches b
      left join public.staff_members abs_staff on abs_staff.staff_id=b.recorded_by_staff_id
      where b.production_flow_item_id=mb.production_flow_item_id
        and b.external_system_code='ABS'
    ) abs_data on true
  )
  select
    coalesce(jsonb_agg(to_jsonb(t) order by t.recorded_at desc,t.mop_production_batch_id desc),'[]'::jsonb),
    count(*) filter(where t.abs_status='PENDING')::integer,
    count(*) filter(where t.abs_status='POSTED')::integer
  into v_rows,v_pending,v_posted
  from trace_rows t;

  return jsonb_build_object(
    'rows',v_rows,
    'pending_abs_count',v_pending,
    'posted_abs_count',v_posted,
    'limit',v_limit,
    'source','MOP_PRODUCTION_PLUS_SHARED_PRODUCTION_FLOW_ABS'
  );
end;
$$;

revoke all on function public.get_sorting_mop_recent_trace(integer)
  from public, anon, authenticated;
grant execute on function public.get_sorting_mop_recent_trace(integer)
  to authenticated;

comment on function public.get_sorting_mop_recent_trace(integer)
  is 'Compact MOP Production trace with processed MOP lines, trolley evidence and current shared ABS batch posting details. Direct source tables remain private.';

commit;
