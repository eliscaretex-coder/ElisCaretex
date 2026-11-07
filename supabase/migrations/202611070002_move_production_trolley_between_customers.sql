-- Move a clean trolley from one customer to another during production.
--
-- On the production floor a clean trolley already scanned (saved) for customer A in
-- Finish or MOP Production is often taken and used for customer B. Until now the scan
-- for B was hard-blocked ("trolley already has an open customer stay"), the Finish Edit
-- refused to remove a trolley and the MOP correction pointed to a review that cannot
-- move it, so there was no way out on screen.
--
-- New RPCs, no table or column changes:
--
-- get_production_trolley_move_v1(code, target flow)
--   Read-only. Says which customer / area / record holds the trolley now and whether it
--   can be moved to the target customer.
--
-- release_production_trolley_v1(code, target flow, reason)
--   Takes the trolley out of customer A so it can be scanned for customer B:
--   * only a trolley still IN_PRODUCTION whose open stay was opened by Finish or MOP
--     Production and whose planned delivery is today or later (not delivered yet);
--   * the trolley link is removed from A's current Finish record / MOP Production
--     record, and that record becomes "Trolley pending" when it now has fewer trolleys
--     than planned (A scans another trolley later with Edit / Add trolley);
--   * the mistaken production stay is removed and the trolley is AVAILABLE again; the
--     normal save for B then assigns it exactly like any other trolley;
--   * a reason is required (at least 5 characters, owner rule 2026-11-07);
--   * evidence: trolley_events RECORD_CORRECTED (with the reason and the full old stay)
--     and audit_log.
--   The caller needs the area access of the target customer (Finish or MOP Production),
--   the same people who scan trolleys there.
--
-- Plan checks are unchanged: an L trolley still counts as M.

create or replace function public.production_trolley_move_state(
  p_trolley_code text,
  p_target_flow_item_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_target public.production_flow_items%rowtype;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_customer public.customers%rowtype;
  v_finish_entry uuid;
  v_mop_batch uuid;
  v_source_flow uuid;
  v_table text;
  v_can boolean := false;
  v_reason text;
begin
  select * into v_target
  from public.production_flow_items
  where production_flow_item_id = p_target_flow_item_id;
  if not found or v_target.product_code not in ('CLOTHES','MOP') then
    raise exception using errcode = '22023', message = 'A valid Finish or MOP Production customer is required.';
  end if;

  if nullif(trim(coalesce(p_trolley_code,'')),'') is null then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null;
  if not found then
    return jsonb_build_object('trolley_code', upper(trim(p_trolley_code)), 'can_move', false,
      'reason', format('%s: trolley not found.', upper(trim(p_trolley_code))));
  end if;

  select * into v_stay
  from public.trolley_customer_stays s
  where s.trolley_id = v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc
  limit 1;

  if v_stay.stay_id is not null then
    select * into v_customer from public.customers c where c.customer_id = v_stay.outbound_customer_id;

    select e.finish_production_entry_id, e.production_flow_item_id, coalesce(e.table_name_snapshot, e.table_code_snapshot)
    into v_finish_entry, v_source_flow, v_table
    from public.finish_production_trolleys ft
    join public.finish_production_entries e on e.finish_production_entry_id = ft.finish_production_entry_id
    where ft.stay_id = v_stay.stay_id and e.status = 'ACTIVE'
    order by e.recorded_at desc nulls last
    limit 1;

    if v_finish_entry is null then
      select b.mop_production_batch_id, b.production_flow_item_id
      into v_mop_batch, v_source_flow
      from public.sorting_mop_production_trolleys mt
      join public.sorting_mop_production_batches b on b.mop_production_batch_id = mt.mop_production_batch_id
      where mt.stay_id = v_stay.stay_id and b.status = 'RECORDED'
      order by b.created_at desc
      limit 1;
    end if;
  end if;

  if v_stay.stay_id is null then
    v_reason := 'This trolley is not assigned to any customer. Scan it normally.';
  elsif v_stay.production_area_code is null then
    v_reason := 'This trolley is at a customer (not from Finish or MOP Production). It cannot be moved here.';
  elsif v_trolley.status <> 'IN_PRODUCTION' then
    v_reason := format('This trolley is %s. Only a trolley still in production can be moved.', v_trolley.status);
  elsif v_stay.planned_delivery_on < public.current_business_date() then
    v_reason := 'The delivery date of this trolley has passed, so it is considered delivered. It cannot be moved.';
  elsif v_finish_entry is null and v_mop_batch is null then
    v_reason := 'No current Finish or MOP Production record holds this trolley. Ask a manager to review it.';
  elsif v_source_flow = v_target.production_flow_item_id then
    v_reason := 'This trolley is already saved for this customer.';
  else
    v_can := true;
  end if;

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'trolley_status', v_trolley.status,
    'stay_id', v_stay.stay_id,
    'from_customer_id', v_stay.outbound_customer_id,
    'from_customer_code', v_customer.customer_code,
    'from_customer_name', v_customer.customer_name,
    'from_area_code', v_stay.production_area_code,
    'from_production_date', v_stay.production_business_date,
    'from_delivery_date', v_stay.planned_delivery_on,
    'from_table', v_table,
    'from_flow_item_id', v_source_flow,
    'finish_production_entry_id', v_finish_entry,
    'mop_production_batch_id', v_mop_batch,
    'to_flow_item_id', v_target.production_flow_item_id,
    'to_customer_id', v_target.customer_id,
    'to_customer_name', v_target.customer_name_snapshot,
    'to_area_code', case when v_target.product_code = 'MOP' then 'MOP' else 'FINISH' end,
    'can_move', v_can,
    'reason', v_reason
  );
end;
$$;

revoke all on function public.production_trolley_move_state(text,uuid) from public, anon, authenticated;

create or replace function public.require_production_trolley_move_access(p_target_flow_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_product text;
begin
  select pfi.product_code into v_product
  from public.production_flow_items pfi
  where pfi.production_flow_item_id = p_target_flow_item_id;
  if v_product = 'MOP' then
    perform public.begin_mop_operational_scope();
  elsif v_product = 'CLOTHES' then
    perform public.require_finish_production_access();
  else
    raise exception using errcode = '22023', message = 'A valid Finish or MOP Production customer is required.';
  end if;
end;
$$;

revoke all on function public.require_production_trolley_move_access(uuid) from public, anon, authenticated;

create or replace function public.get_production_trolley_move_v1(
  p_trolley_code text,
  p_target_flow_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_trolley_move_access(p_target_flow_item_id);
  return public.production_trolley_move_state(p_trolley_code, p_target_flow_item_id);
end;
$$;

revoke all on function public.get_production_trolley_move_v1(text,uuid) from public, anon;
grant execute on function public.get_production_trolley_move_v1(text,uuid) to authenticated;

create or replace function public.release_production_trolley_v1(
  p_trolley_code text,
  p_target_flow_item_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_state jsonb;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_staff uuid;
  v_reason text;
  v_entry public.finish_production_entries%rowtype;
  v_batch public.sorting_mop_production_batches%rowtype;
  v_planned integer := 0;
  v_remaining integer := 0;
  v_old_status text;
  v_new_status text;
  v_record_table text;
  v_record_id uuid;
begin
  perform public.require_production_trolley_move_access(p_target_flow_item_id);

  v_reason := nullif(trim(coalesce(p_reason,'')),'');
  if v_reason is null or length(v_reason) < 5 then
    raise exception using errcode = '22023', message = 'Write why this trolley is moved (at least 5 characters).';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode = '22023', message = 'Reason must be 500 characters or fewer.';
  end if;

  -- Lock the trolley first so two screens cannot move it at the same time.
  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(coalesce(p_trolley_code,'')))
    and t.deleted_at is null
  for update;

  v_state := public.production_trolley_move_state(p_trolley_code, p_target_flow_item_id);
  if not coalesce((v_state->>'can_move')::boolean, false) then
    raise exception using errcode = '23514', message = coalesce(v_state->>'reason', 'This trolley cannot be moved.');
  end if;

  select * into v_stay
  from public.trolley_customer_stays s
  where s.stay_id = (v_state->>'stay_id')::uuid
  for update;

  v_staff := public.current_staff_id();

  if v_state->>'finish_production_entry_id' is not null then
    select * into v_entry
    from public.finish_production_entries e
    where e.finish_production_entry_id = (v_state->>'finish_production_entry_id')::uuid
    for update;

    delete from public.finish_production_trolleys ft
    where ft.finish_production_entry_id = v_entry.finish_production_entry_id
      and ft.stay_id = v_stay.stay_id;

    select coalesce(sum(r.quantity),0)::integer into v_planned
    from public.production_flow_items pfi
    join public.customer_schedule_trolley_requirements r
      on r.owner_schedule_product_id = pfi.source_schedule_product_id and r.active = true
    where pfi.production_flow_item_id = v_entry.production_flow_item_id;

    select count(*)::integer into v_remaining
    from public.finish_production_trolleys ft
    where ft.finish_production_entry_id = v_entry.finish_production_entry_id;

    v_old_status := v_entry.trolley_scan_status;
    v_new_status := case when v_remaining < v_planned then 'PENDING' else v_old_status end;
    if v_new_status is distinct from v_old_status then
      update public.finish_production_entries
      set trolley_scan_status = v_new_status
      where finish_production_entry_id = v_entry.finish_production_entry_id;
    end if;
    v_record_table := 'finish_production_entries';
    v_record_id := v_entry.finish_production_entry_id;
  else
    select * into v_batch
    from public.sorting_mop_production_batches b
    where b.mop_production_batch_id = (v_state->>'mop_production_batch_id')::uuid
    for update;

    delete from public.sorting_mop_production_trolleys mt
    where mt.mop_production_batch_id = v_batch.mop_production_batch_id
      and mt.stay_id = v_stay.stay_id;

    v_planned := coalesce(v_batch.planned_output_trolley_quantity, 0);
    select count(*)::integer into v_remaining
    from public.sorting_mop_production_trolleys mt
    where mt.mop_production_batch_id = v_batch.mop_production_batch_id;

    v_old_status := v_batch.trolley_capture_status;
    v_new_status := case
      when v_remaining < v_planned and v_batch.entry_mode = 'LIVE' then 'PENDING'
      else v_old_status
    end;
    if v_new_status is distinct from v_old_status then
      update public.sorting_mop_production_batches
      set trolley_capture_status = v_new_status
      where mop_production_batch_id = v_batch.mop_production_batch_id;
    end if;
    v_record_table := 'sorting_mop_production_batches';
    v_record_id := v_batch.mop_production_batch_id;
  end if;

  -- Older revisions of A's record keep the trolley code as history, without the stay.
  update public.finish_production_trolleys set stay_id = null where stay_id = v_stay.stay_id;
  update public.sorting_mop_production_trolleys set stay_id = null where stay_id = v_stay.stay_id;

  insert into public.trolley_events(
    trolley_id, stay_id, event_type, customer_id, business_date, performed_by, source_application, reason, metadata
  ) values (
    v_trolley.trolley_id, null, 'RECORD_CORRECTED', v_stay.outbound_customer_id, public.current_business_date(),
    v_staff, case when v_state->>'to_area_code' = 'MOP' then 'SORTING_MOP_PRODUCTION' else 'FINISH_V2' end, v_reason,
    jsonb_build_object(
      'action', 'RELEASED_FROM_PRODUCTION_CUSTOMER',
      'from_customer_id', v_stay.outbound_customer_id,
      'from_customer_name', v_state->>'from_customer_name',
      'from_area_code', v_stay.production_area_code,
      'from_record_table', v_record_table,
      'from_record_id', v_record_id,
      'from_trolley_status_before', v_old_status,
      'from_trolley_status_after', v_new_status,
      'to_flow_item_id', p_target_flow_item_id,
      'to_customer_id', v_state->>'to_customer_id',
      'to_customer_name', v_state->>'to_customer_name',
      'removed_stay', to_jsonb(v_stay)
    )
  );

  delete from public.trolley_customer_stays where stay_id = v_stay.stay_id;

  update public.trolleys
  set status = 'AVAILABLE', updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.audit_log(
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_staff, 'RELEASE_PRODUCTION_TROLLEY', 'trolleys', v_trolley.trolley_id::text,
    jsonb_build_object('stay', to_jsonb(v_stay), 'trolley_status', v_trolley.status,
      'record_table', v_record_table, 'record_id', v_record_id, 'record_trolley_status', v_old_status),
    jsonb_build_object('trolley_status', 'AVAILABLE', 'record_trolley_status', v_new_status,
      'to_flow_item_id', p_target_flow_item_id, 'to_customer_id', v_state->>'to_customer_id'),
    v_reason,
    case when v_state->>'to_area_code' = 'MOP' then 'SORTING_MOP_PRODUCTION' else 'FINISH_V2' end
  );

  return jsonb_build_object(
    'status', 'released',
    'trolley_code', v_trolley.trolley_code,
    'from_customer_name', v_state->>'from_customer_name',
    'from_area_code', v_stay.production_area_code,
    'from_record_trolley_status', v_new_status,
    'to_customer_name', v_state->>'to_customer_name',
    'message', format('%s was taken out of %s%s. Save this customer to use it here.',
      v_trolley.trolley_code, coalesce(v_state->>'from_customer_name','the other customer'),
      case when v_new_status = 'PENDING' and v_old_status is distinct from 'PENDING' then ' (it is now Trolley pending there)' else '' end)
  );
end;
$$;

revoke all on function public.release_production_trolley_v1(text,uuid,text) from public, anon;
grant execute on function public.release_production_trolley_v1(text,uuid,text) to authenticated;
