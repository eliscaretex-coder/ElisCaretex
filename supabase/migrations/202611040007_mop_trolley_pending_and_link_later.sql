-- MOP Production: save the production before the clean trolley is available
-- ("No trolley yet") and link the trolley(s) later, like Finish.
--
-- 1. trolley_capture_status accepts PENDING.
-- 2. save_sorting_mop_production (internal) records PENDING instead of refusing
--    when the transaction-local flag eliscaretex.mop_trolley_pending is on. The
--    live definition is patched in place (two exact text replacements) so every
--    other rule of the current function is kept as it is.
-- 3. save_sorting_mop_production_v3: same as v2 plus p_trolley_pending. With
--    pending, fewer trolleys than planned may be scanned (or none).
-- 4. link_sorting_mop_production_trolleys: adds the trolley(s) to a PENDING MOP
--    Production record. Each trolley gets the normal live customer stay. The
--    status becomes RECORDED / RECORDED_MISMATCH when the plan is complete, or
--    stays PENDING while trolleys are still missing. The batch row keeps its
--    revision; the link is recorded as a Production Flow event and in audit_log.

alter table public.sorting_mop_production_batches
  drop constraint sorting_mop_production_trolley_status_check;
alter table public.sorting_mop_production_batches
  add constraint sorting_mop_production_trolley_status_check
  check (trolley_capture_status = any (array[
    'NOT_REQUIRED','RECORDED','RECORDED_MISMATCH','UNPLANNED_RECORDED',
    'UNKNOWN_LATE_ENTRY','LATE_RECORDED_CODE','PENDING'
  ]));

do $patch$
declare
  v_def text := pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)'::regprocedure);
  v_old text := 'elsif cardinality(v_trolley_codes)=v_planned_trolley_qty then v_trolley_status:=''RECORDED'';';
  v_new text := 'elsif v_planned_trolley_qty>0 and coalesce(current_setting(''eliscaretex.mop_trolley_pending'',true),'''')=''on'' then v_trolley_status:=''PENDING'';'
    || chr(10) || '    elsif cardinality(v_trolley_codes)=v_planned_trolley_qty then v_trolley_status:=''RECORDED'';';
begin
  if position('eliscaretex.mop_trolley_pending' in v_def) > 0 then
    raise notice 'save_sorting_mop_production already accepts pending trolleys.';
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'save_sorting_mop_production changed: the trolley status line was not found exactly once. Review before applying.';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$patch$;

revoke all on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text) from public, anon, authenticated;

create or replace function public.save_sorting_mop_production_v3(
  p_shift_code text,
  p_production_flow_item_id uuid,
  p_operator_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_unknown boolean default false,
  p_physical_processed_on date default null,
  p_physical_processed_time time default null,
  p_entry_mode text default 'LIVE',
  p_notes text default null,
  p_accept_trolley_mismatch boolean default false,
  p_trolley_pending boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_validation jsonb;
  v_result jsonb;
begin
  perform public.begin_mop_operational_scope();

  if not coalesce(p_trolley_pending, false) then
    return public.save_sorting_mop_production_v2(
      p_shift_code, p_production_flow_item_id, p_operator_staff_id, p_lines, p_trolley_codes,
      p_trolley_unknown, p_physical_processed_on, p_physical_processed_time, p_entry_mode,
      p_notes, p_accept_trolley_mismatch
    ) || jsonb_build_object('trolley_pending', false);
  end if;

  if upper(trim(coalesce(p_entry_mode, 'LIVE'))) <> 'LIVE' or coalesce(p_trolley_unknown, false) then
    raise exception using errcode = '22023',
      message = 'No trolley yet is only for live MOP Production. A missed entry uses Trolley number no longer available.';
  end if;

  v_validation := public.validate_mop_trolley_selection(p_production_flow_item_id, p_trolley_codes);
  if coalesce((v_validation->>'hard_block')::boolean, false) then
    raise exception using errcode = '23514',
      message = 'One or more scanned trolleys cannot be used. Review the MOP trolley scan.';
  end if;
  if coalesce((v_validation->>'planned_total')::integer, 0) = 0 then
    raise exception using errcode = '22023',
      message = 'This MOP customer has no planned trolley, so nothing can be left pending.';
  end if;
  if coalesce((v_validation->>'scanned_total')::integer, 0) >= coalesce((v_validation->>'planned_total')::integer, 0) then
    raise exception using errcode = '22023',
      message = 'Every planned trolley is already scanned. Save without No trolley yet.';
  end if;

  perform set_config('eliscaretex.mop_trolley_pending', 'on', true);
  begin
    v_result := public.save_sorting_mop_production(
      p_shift_code, p_production_flow_item_id, p_operator_staff_id, p_lines, p_trolley_codes,
      false, null, null, 'LIVE', p_notes
    );
  exception when others then
    perform set_config('eliscaretex.mop_trolley_pending', 'off', true);
    raise;
  end;
  perform set_config('eliscaretex.mop_trolley_pending', 'off', true);

  return v_result || jsonb_build_object(
    'trolley_validation', v_validation,
    'trolley_pending', true,
    'message', format('MOP production recorded. %s of %s trolley(s) still to scan: use Add trolley in MOP Production Trace when the trolley is ready.',
      coalesce((v_validation->>'planned_total')::integer, 0) - coalesce((v_validation->>'scanned_total')::integer, 0),
      coalesce((v_validation->>'planned_total')::integer, 0))
  );
end;
$$;

revoke all on function public.save_sorting_mop_production_v3(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean,boolean) from public, anon;
grant execute on function public.save_sorting_mop_production_v3(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean,boolean) to authenticated;

create or replace function public.link_sorting_mop_production_trolleys(
  p_mop_production_batch_id uuid,
  p_trolley_codes text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_actor_staff_id uuid;
  v_codes text[];
  v_existing text[];
  v_all text[];
  v_validation jsonb;
  v_code text;
  v_assign jsonb;
  v_planned integer;
  v_status text;
begin
  perform public.begin_mop_operational_scope();
  v_actor_staff_id := public.current_staff_id();

  select * into v_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id = p_mop_production_batch_id
  for update;
  if not found or v_batch.status <> 'RECORDED' then
    raise exception using errcode = 'P0002', message = 'Only the current active MOP Production record can receive a trolley.';
  end if;
  if v_batch.entry_mode <> 'LIVE' or v_batch.trolley_capture_status <> 'PENDING' then
    raise exception using errcode = '22023', message = 'This MOP Production record is not waiting for a trolley.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id = v_batch.production_flow_item_id
  for update;
  if not found or v_flow.product_code <> 'MOP' or v_flow.scheduled_for_date is null then
    raise exception using errcode = '22023', message = 'Live trolley assignment requires a scheduled MOP customer.';
  end if;

  select coalesce(array_agg(code order by code), array[]::text[]) into v_codes
  from (
    select distinct upper(trim(x)) as code
    from unnest(coalesce(p_trolley_codes, array[]::text[])) x
    where nullif(trim(x), '') is not null
  ) q;
  if cardinality(v_codes) = 0 then
    raise exception using errcode = '22023', message = 'Scan at least one trolley.';
  end if;
  if exists (select 1 from unnest(v_codes) x where x !~ '^T[0-9]{1,10}T$') then
    raise exception using errcode = '22023', message = 'Invalid trolley code. Expected format like T123T.';
  end if;

  select coalesce(array_agg(upper(mt.trolley_code_snapshot) order by mt.created_at), array[]::text[]) into v_existing
  from public.sorting_mop_production_trolleys mt
  where mt.mop_production_batch_id = v_batch.mop_production_batch_id;
  if exists (select 1 from unnest(v_codes) x where x = any (v_existing)) then
    raise exception using errcode = '23505', message = 'A scanned trolley is already linked to this MOP Production.';
  end if;

  v_validation := public.validate_mop_trolley_selection(v_flow.production_flow_item_id, v_codes);
  if coalesce((v_validation->>'hard_block')::boolean, false) then
    raise exception using errcode = '23514',
      message = coalesce((select string_agg(x, ' ') from jsonb_array_elements_text(v_validation->'hard_issues') x),
        'One or more scanned trolleys cannot be used.');
  end if;

  foreach v_code in array v_codes loop
    v_assign := public.assign_trolley_to_customer_from_production(
      v_code, v_flow.customer_id, v_flow.scheduled_for_date, 'MOP',
      format('MOP Production %s (trolley linked later)', v_batch.mop_production_batch_id),
      'SORTING_MOP_PRODUCTION'
    );
    insert into public.sorting_mop_production_trolleys(
      mop_production_batch_id, trolley_id, trolley_code_snapshot, stay_id, lifecycle_action
    ) values (
      v_batch.mop_production_batch_id, nullif(v_assign->>'trolley_id', '')::uuid, v_code,
      nullif(v_assign->>'stay_id', '')::uuid, 'LIVE_ASSIGNMENT'
    );
  end loop;

  v_all := v_existing || v_codes;
  v_planned := coalesce(v_batch.planned_output_trolley_quantity, 0);
  -- Type match over every linked trolley (the stays just opened are not a problem for
  -- the plan comparison, only for the hard checks already done above).
  v_validation := public.validate_mop_trolley_selection(v_flow.production_flow_item_id, v_all);
  v_status := case
    when cardinality(v_all) < v_planned then 'PENDING'
    when coalesce((v_validation->>'matches_plan')::boolean, false) then 'RECORDED'
    else 'RECORDED_MISMATCH'
  end;

  update public.sorting_mop_production_batches
  set trolley_capture_status = v_status
  where mop_production_batch_id = v_batch.mop_production_batch_id;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id, 'MOP_TROLLEY_LINKED_LATER', 'PRODUCTION', 40, 'MOP',
    v_batch.business_date, now(), v_batch.operator_staff_id, v_actor_staff_id, auth.uid(),
    'SORTING_MOP_PRODUCTION', 'sorting_mop_production_batches', v_batch.mop_production_batch_id::text,
    jsonb_build_object(
      'added_trolley_codes', to_jsonb(v_codes),
      'trolley_codes', to_jsonb(v_all),
      'planned_output_trolley_quantity', v_planned,
      'old_trolley_capture_status', v_batch.trolley_capture_status,
      'trolley_capture_status', v_status
    )
  );

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (
    auth.uid(), v_actor_staff_id, 'LINK_SORTING_MOP_PRODUCTION_TROLLEYS', 'sorting_mop_production_batches',
    v_batch.mop_production_batch_id::text,
    jsonb_build_object('trolley_capture_status', v_batch.trolley_capture_status, 'trolley_codes', to_jsonb(v_existing)),
    jsonb_build_object('trolley_capture_status', v_status, 'trolley_codes', to_jsonb(v_all)),
    'Trolley linked after MOP Production was saved.', 'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'mop_production_batch_id', v_batch.mop_production_batch_id,
    'production_flow_item_id', v_flow.production_flow_item_id,
    'customer_name', v_flow.customer_name_snapshot,
    'trolley_codes', to_jsonb(v_all),
    'added_trolley_codes', to_jsonb(v_codes),
    'planned_output_trolley_quantity', v_planned,
    'trolley_capture_status', v_status,
    'message', case
      when v_status = 'PENDING' then format('%s linked. %s trolley(s) still to scan.', array_to_string(v_codes, ', '), v_planned - cardinality(v_all))
      when v_status = 'RECORDED' then format('%s linked. All planned trolleys are now scanned.', array_to_string(v_codes, ', '))
      else format('%s linked. Trolley quantity / size differs from the published plan.', array_to_string(v_codes, ', '))
    end
  );
end;
$$;

revoke all on function public.link_sorting_mop_production_trolleys(uuid,text[]) from public, anon;
grant execute on function public.link_sorting_mop_production_trolleys(uuid,text[]) to authenticated;
