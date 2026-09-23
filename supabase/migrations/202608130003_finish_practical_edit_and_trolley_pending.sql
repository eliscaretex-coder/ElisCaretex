-- =====================================================================
-- ElisCaretex V2
-- Migration 049: Finish practical edit + trolley pending/status contract
--
-- PREPARED: owner executes in Development.
--
-- Goals:
-- 1. Keep Finish corrections append-only but do not require a typed reason for
--    normal production edits before the Delivery Date 12:00 cutoff.
-- 2. Record whether trolley evidence MATCHED the published plan, was accepted
--    as a MISMATCH, is PENDING because no trolley is available yet, or was
--    NOT_REQUIRED.
-- 3. Expose V3 RPCs so the frontend can explicitly distinguish "No trolley yet"
--    from an accidental empty scan.
-- =====================================================================

begin;

alter table public.finish_production_entries
  add column if not exists trolley_scan_status text not null default 'UNSPECIFIED';

alter table public.finish_production_entries
  drop constraint if exists finish_production_entries_trolley_scan_status_check;

alter table public.finish_production_entries
  add constraint finish_production_entries_trolley_scan_status_check
  check (trolley_scan_status in ('UNSPECIFIED','MATCHED','MISMATCH','PENDING','NOT_REQUIRED'));

comment on column public.finish_production_entries.trolley_scan_status is
  'Finish trolley evidence state for this revision: MATCHED, MISMATCH, PENDING, NOT_REQUIRED, or UNSPECIFIED for earlier records.';

-- ---------------------------------------------------------------------
-- Normal operational edits are frequent in Finish. Keep the append-only
-- revision history but allow correction_reason to be null.
-- ---------------------------------------------------------------------
create or replace function public.correct_finish_production(
  p_finish_production_entry_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_notes text default null,
  p_correction_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.finish_production_entries%rowtype; v_new public.finish_production_entries%rowtype; v_clean jsonb; v_line jsonb;
  v_reason text:=nullif(trim(coalesce(p_correction_reason,'')),''); v_staff uuid; v_old_codes text[]; v_new_codes text[]; v_code text; v_assign jsonb;
  v_total_kg numeric:=0; v_total_units numeric:=0;
begin
  perform public.require_finish_production_access();
  select * into v_old from public.finish_production_entries where finish_production_entry_id=p_finish_production_entry_id and status='ACTIVE' for update;
  if not found then raise exception using errcode='P0002', message='The active Finish record was not found.'; end if;
  perform public.finish_assert_entry_open(v_old.production_flow_item_id,now());
  v_clean:=public.finish_validate_lines(v_old.production_flow_item_id,v_old.production_business_date,p_lines,v_old.entry_group_id);
  select coalesce(array_agg(upper(trolley_code_snapshot) order by upper(trolley_code_snapshot)),array[]::text[]) into v_old_codes from public.finish_production_trolleys where finish_production_entry_id=v_old.finish_production_entry_id;
  select coalesce(array_agg(distinct upper(trim(x)) order by upper(trim(x))),array[]::text[]) into v_new_codes from unnest(coalesce(p_trolley_codes,array[]::text[])) x where nullif(trim(x),'') is not null;

  -- Existing physical lifecycle links may not be silently removed by a normal
  -- production edit. A dedicated governed trolley correction remains required.
  if exists(select 1 from unnest(v_old_codes) x where not (x=any(v_new_codes))) then
    raise exception using errcode='23514', message='A trolley already assigned by Finish cannot be removed through Edit because its physical lifecycle is already open. Keep the scanned trolley and correct the production values, or use a separately governed trolley correction workflow.';
  end if;

  v_staff:=public.current_staff_id();
  update public.finish_production_entries set status='SUPERSEDED' where finish_production_entry_id=v_old.finish_production_entry_id;

  insert into public.finish_production_entries(
    entry_group_id,revision_no,status,supersedes_finish_production_entry_id,
    production_flow_item_id,customer_id,production_business_date,delivery_date,
    edit_cutoff_at,shift_id,shift_code_snapshot,station_id,table_code_snapshot,
    table_name_snapshot,notes,correction_reason,source_application,
    recorded_by_staff_id,recorded_by_auth_user_id,trolley_scan_status
  ) values(
    v_old.entry_group_id,v_old.revision_no+1,'ACTIVE',v_old.finish_production_entry_id,
    v_old.production_flow_item_id,v_old.customer_id,v_old.production_business_date,
    v_old.delivery_date,v_old.edit_cutoff_at,v_old.shift_id,v_old.shift_code_snapshot,
    v_old.station_id,v_old.table_code_snapshot,v_old.table_name_snapshot,
    nullif(trim(p_notes),''),v_reason,'FINISH_V2',v_staff,auth.uid(),v_old.trolley_scan_status
  ) returning * into v_new;

  for v_line in select value from jsonb_array_elements(v_clean) loop
    insert into public.finish_production_lines(finish_production_entry_id,line_no,batch_reference,unit_code,quantity)
    values(v_new.finish_production_entry_id,(v_line->>'line_no')::integer,v_line->>'batch_reference',v_line->>'unit_code',(v_line->>'quantity')::numeric);
    if v_line->>'unit_code'='KG' then v_total_kg:=v_total_kg+(v_line->>'quantity')::numeric; else v_total_units:=v_total_units+(v_line->>'quantity')::numeric; end if;
  end loop;

  insert into public.finish_production_trolleys(finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id)
  select v_new.finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id
  from public.finish_production_trolleys where finish_production_entry_id=v_old.finish_production_entry_id;

  for v_code in select x from unnest(v_new_codes) x where not (x=any(v_old_codes)) loop
    v_assign:=public.assign_finish_trolley_to_flow(v_code,v_old.production_flow_item_id,v_old.production_business_date,'Finish edit '||v_new.finish_production_entry_id::text);
    insert into public.finish_production_trolleys(finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id)
    values(v_new.finish_production_entry_id,(v_assign->>'trolley_id')::uuid,v_assign->>'trolley_code',(v_assign->>'stay_id')::uuid);
  end loop;

  insert into public.production_flow_events(
    production_flow_item_id,event_type,stage_code,stage_rank,area_code,business_date,
    occurred_at,performed_by_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,
    source_application,source_entity_table,source_entity_id,event_data
  ) values(
    v_old.production_flow_item_id,'FINISH_PRODUCTION_CORRECTED','PRODUCTION',40,'FINISH',v_old.production_business_date,
    now(),v_staff,v_staff,auth.uid(),'FINISH_V2','finish_production_entries',v_new.finish_production_entry_id::text,
    jsonb_build_object('entry_group_id',v_old.entry_group_id,'revision_no',v_new.revision_no,'supersedes',v_old.finish_production_entry_id,'correction_reason',v_reason,'processed_kg',v_total_kg,'processed_units',v_total_units)
  );

  update public.production_flow_items
  set last_event_type='FINISH_PRODUCTION_CORRECTED',last_event_at=now(),last_area_code='FINISH',
      last_performed_by_staff_id=v_staff,event_count=event_count+1,updated_at=now(),row_version=row_version+1
  where production_flow_item_id=v_old.production_flow_item_id;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
  ) values(
    auth.uid(),v_staff,'CORRECT_FINISH_PRODUCTION','finish_production_entries',v_new.finish_production_entry_id::text,
    to_jsonb(v_old),jsonb_build_object('entry',to_jsonb(v_new),'lines',v_clean,'trolley_codes',to_jsonb(v_new_codes)),v_reason,'FINISH_V2'
  );

  return jsonb_build_object(
    'status','corrected','finish_production_entry_id',v_new.finish_production_entry_id,
    'entry_group_id',v_new.entry_group_id,'revision_no',v_new.revision_no,
    'processed_kg',v_total_kg,'processed_units',v_total_units
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Central trolley-state resolver. This is deliberately private to the
-- authenticated client; public V3 RPCs call it server-side.
-- ---------------------------------------------------------------------
create or replace function public.finish_resolve_trolley_scan_status(
  p_production_flow_item_id uuid,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_pending boolean default false,
  p_accept_trolley_mismatch boolean default false,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_check jsonb;
  v_codes text[];
  v_planned integer;
  v_scanned integer;
  v_status text;
begin
  perform public.require_finish_production_access();

  select coalesce(array_agg(distinct upper(trim(x)) order by upper(trim(x))),array[]::text[])
  into v_codes
  from unnest(coalesce(p_trolley_codes,array[]::text[])) x
  where nullif(trim(x),'') is not null;

  if coalesce(p_trolley_pending,false) and coalesce(array_length(v_codes,1),0)>0 then
    raise exception using errcode='22023', message='No trolley yet cannot be used when trolley codes are already scanned.';
  end if;

  v_check:=public.validate_finish_trolley_selection(
    p_production_flow_item_id,v_codes,coalesce(p_at,now())
  );
  v_planned:=coalesce((v_check->>'planned_total')::integer,0);
  v_scanned:=coalesce((v_check->>'scanned_total')::integer,0);

  if coalesce((v_check->>'hard_block')::boolean,false) then
    raise exception using errcode='23514', message='One or more scanned trolleys cannot be used. Review the trolley scan.';
  end if;

  if coalesce(p_trolley_pending,false) then
    v_status:=case when v_planned=0 then 'NOT_REQUIRED' else 'PENDING' end;
  elsif v_planned=0 and v_scanned=0 then
    v_status:='NOT_REQUIRED';
  elsif coalesce((v_check->>'matches_plan')::boolean,false) then
    v_status:='MATCHED';
  else
    if v_scanned=0 and v_planned>0 then
      raise exception using errcode='23514', message='No trolley has been scanned. Scan the trolley or choose No trolley yet.';
    end if;
    if not coalesce(p_accept_trolley_mismatch,false) then
      raise exception using errcode='23514', message='Trolley quantity/type does not match the published plan. Review the scan or explicitly accept the mismatch.';
    end if;
    v_status:='MISMATCH';
  end if;

  return jsonb_build_object(
    'status',v_status,
    'validation',v_check,
    'planned_total',v_planned,
    'scanned_total',v_scanned
  );
end;
$$;

revoke all on function public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamptz)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- V3 record RPC: keeps the already tested V2 staff attribution path and adds
-- explicit trolley evidence status.
-- ---------------------------------------------------------------------
create or replace function public.record_finish_production_v3(
  p_production_flow_item_id uuid,
  p_shift_code text,
  p_table_code text,
  p_processed_by_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_pending boolean default false,
  p_accept_trolley_mismatch boolean default false,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_trolley jsonb;
  v_result jsonb;
  v_entry_id uuid;
  v_status text;
begin
  perform public.require_finish_production_access();

  v_trolley:=public.finish_resolve_trolley_scan_status(
    p_production_flow_item_id,p_trolley_codes,p_trolley_pending,p_accept_trolley_mismatch,now()
  );
  v_status:=v_trolley->>'status';

  v_result:=public.record_finish_production_v2(
    p_production_flow_item_id,p_shift_code,p_table_code,p_processed_by_staff_id,
    p_lines,p_trolley_codes,p_notes
  );
  v_entry_id:=nullif(v_result->>'finish_production_entry_id','')::uuid;
  if v_entry_id is null then
    raise exception using errcode='P0002', message='Finish production save did not return an entry id.';
  end if;

  update public.finish_production_entries
  set trolley_scan_status=v_status
  where finish_production_entry_id=v_entry_id;

  update public.production_flow_events
  set event_data=coalesce(event_data,'{}'::jsonb)||jsonb_build_object(
    'trolley_scan_status',v_status,
    'trolley_plan_matches',coalesce((v_trolley#>>'{validation,matches_plan}')::boolean,false),
    'trolley_pending',coalesce(p_trolley_pending,false)
  )
  where source_application='FINISH_V2'
    and source_entity_table='finish_production_entries'
    and source_entity_id=v_entry_id::text
    and event_type='FINISH_PRODUCTION_RECORDED';

  return v_result||jsonb_build_object(
    'trolley_scan_status',v_status,
    'trolley_validation',v_trolley->'validation'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- V3 correction RPC: quick edits remain append-only. No typed reason is
-- required. Processor attribution remains explicit and traceable.
-- ---------------------------------------------------------------------
create or replace function public.correct_finish_production_v3(
  p_finish_production_entry_id uuid,
  p_processed_by_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_pending boolean default false,
  p_accept_trolley_mismatch boolean default false,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.finish_production_entries%rowtype;
  v_processor public.staff_members%rowtype;
  v_trolley jsonb;
  v_result jsonb;
  v_new_id uuid;
  v_actor_staff uuid;
  v_status text;
begin
  perform public.require_finish_production_access();

  select * into v_old
  from public.finish_production_entries e
  where e.finish_production_entry_id=p_finish_production_entry_id
    and e.status='ACTIVE';
  if not found then
    raise exception using errcode='P0002', message='The active Finish record was not found.';
  end if;

  if p_processed_by_staff_id is not distinct from v_old.processed_by_staff_id then
    select * into v_processor
    from public.staff_members sm
    where sm.staff_id=p_processed_by_staff_id
      and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null;
    if not found then
      raise exception using errcode='22023', message='Select an active Finish production staff member.';
    end if;
  else
    select * into v_processor
    from public.finish_assert_processing_staff(
      p_processed_by_staff_id,v_old.production_business_date,v_old.shift_id,v_old.station_id,
      coalesce(v_old.recorded_at,now())
    );
  end if;

  v_trolley:=public.finish_resolve_trolley_scan_status(
    v_old.production_flow_item_id,p_trolley_codes,p_trolley_pending,p_accept_trolley_mismatch,now()
  );
  v_status:=v_trolley->>'status';

  v_result:=public.correct_finish_production(
    p_finish_production_entry_id,p_lines,p_trolley_codes,p_notes,null
  );
  v_new_id:=nullif(v_result->>'finish_production_entry_id','')::uuid;
  if v_new_id is null then
    raise exception using errcode='P0002', message='Finish edit did not return a new revision id.';
  end if;

  update public.finish_production_entries e
  set processed_by_staff_id=v_processor.staff_id,
      processed_by_name_snapshot=v_processor.display_name,
      trolley_scan_status=v_status
  where e.finish_production_entry_id=v_new_id;

  update public.production_flow_events ev
  set performed_by_staff_id=v_processor.staff_id,
      event_data=coalesce(ev.event_data,'{}'::jsonb)||jsonb_build_object(
        'processed_by_staff_id',v_processor.staff_id,
        'processed_by_name',v_processor.display_name,
        'recorded_by_scanner_staff_id',public.current_staff_id(),
        'recorded_by_auth_user_id',auth.uid(),
        'trolley_scan_status',v_status,
        'trolley_plan_matches',coalesce((v_trolley#>>'{validation,matches_plan}')::boolean,false),
        'trolley_pending',coalesce(p_trolley_pending,false)
      )
  where ev.source_application='FINISH_V2'
    and ev.source_entity_table='finish_production_entries'
    and ev.source_entity_id=v_new_id::text
    and ev.event_type='FINISH_PRODUCTION_CORRECTED';

  update public.production_flow_items pfi
  set last_performed_by_staff_id=v_processor.staff_id
  where pfi.production_flow_item_id=v_old.production_flow_item_id
    and pfi.last_event_type='FINISH_PRODUCTION_CORRECTED';

  v_actor_staff:=public.current_staff_id();
  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,source_application
  ) values (
    auth.uid(),v_actor_staff,'ATTRIBUTE_FINISH_EDIT_STAFF','finish_production_entries',v_new_id::text,
    jsonb_build_object('processed_by_staff_id',v_old.processed_by_staff_id,'processed_by_name',v_old.processed_by_name_snapshot,'trolley_scan_status',v_old.trolley_scan_status),
    jsonb_build_object('processed_by_staff_id',v_processor.staff_id,'processed_by_name',v_processor.display_name,'recorded_by_scanner_staff_id',v_actor_staff,'trolley_scan_status',v_status),
    'FINISH_V2'
  );

  return v_result||jsonb_build_object(
    'processed_by_staff_id',v_processor.staff_id,
    'processed_by_name',v_processor.display_name,
    'recorded_by_scanner_staff_id',v_actor_staff,
    'trolley_scan_status',v_status,
    'trolley_validation',v_trolley->'validation'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- V3 read context: enrich V2 entries with trolley_scan_status.
-- ---------------------------------------------------------------------
create or replace function public.get_finish_production_context_v3(
  p_shift_code text default 'MORNING',
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb;
  v_entries jsonb;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context_v2(p_shift_code,p_at);

  with base_entries as (
    select item,ordinality
    from jsonb_array_elements(coalesce(v_base->'entries','[]'::jsonb)) with ordinality x(item,ordinality)
  )
  select coalesce(jsonb_agg(
    b.item||jsonb_build_object('trolley_scan_status',coalesce(e.trolley_scan_status,'UNSPECIFIED'))
    order by b.ordinality
  ),'[]'::jsonb)
  into v_entries
  from base_entries b
  left join public.finish_production_entries e
    on e.finish_production_entry_id=nullif(b.item->>'finish_production_entry_id','')::uuid;

  return (v_base-'schema_version'-'source_contract'-'entries')||jsonb_build_object(
    'schema_version','FINISH_PRODUCTION_V3',
    'source_contract','FINISH_V3_PRACTICAL_EDIT_TROLLEY_STATUS',
    'entries',v_entries,
    'typed_correction_reason_required',false,
    'trolley_pending_supported',true
  );
end;
$$;

revoke all on function public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) from public,anon;
revoke all on function public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text) from public,anon;
revoke all on function public.get_finish_production_context_v3(text,timestamptz) from public,anon;

grant execute on function public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) to authenticated;
grant execute on function public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text) to authenticated;
grant execute on function public.get_finish_production_context_v3(text,timestamptz) to authenticated;

comment on function public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text) is
  'Finish production save with processor attribution and explicit trolley MATCHED/MISMATCH/PENDING/NOT_REQUIRED state.';
comment on function public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text) is
  'Append-only practical Finish edit. No typed correction reason required before the governed cutoff; processor and trolley status remain traceable.';

commit;
