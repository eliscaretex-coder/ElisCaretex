-- ElisCaretex V2
-- Migration 035: Sorting MOP Production Correction / Cancellation
-- Status: PREPARED — OWNER MUST RUN
--
-- Purpose
-- 1. Add append-only revision metadata to MOP Production batches.
-- 2. Correct MOP type/KG/Units/notes by superseding the active batch, never rewriting it.
-- 3. Preserve live physical trolley lifecycle evidence; live trolley codes cannot be changed here.
-- 4. Allow late-reference-only trolley evidence to be corrected without inventing custody.
-- 5. Keep shared ABS evidence aligned when a MOP correction changes the recorded total.
-- 6. Allow explicit cancellation when safe. Live trolley lifecycle prevents cancellation here and
--    must be reviewed in Trolley Control. Linked ABS evidence requires explicit local-trace cancellation.
-- 7. Extend the MOP Trace with revision/cancellation history and correction controls.
--
-- IMPORTANT: owner-run SQL only. ChatGPT must not execute this migration against Supabase.

begin;

-- ---------------------------------------------------------------------
-- 1. Append-only revision metadata.
-- ---------------------------------------------------------------------

alter table public.sorting_mop_production_batches
  add column if not exists supersedes_mop_production_batch_id uuid
    references public.sorting_mop_production_batches(mop_production_batch_id) on delete restrict,
  add column if not exists revision_no integer not null default 1,
  add column if not exists change_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  add column if not exists cancelled_by_auth_user_id uuid
    references auth.users(id) on delete set null,
  add column if not exists cancellation_reason text,
  add column if not exists cancellation_kind text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.sorting_mop_production_batches'::regclass
      and conname='sorting_mop_production_revision_no_check'
  ) then
    alter table public.sorting_mop_production_batches
      add constraint sorting_mop_production_revision_no_check
      check (revision_no >= 1);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.sorting_mop_production_batches'::regclass
      and conname='sorting_mop_production_cancellation_kind_check'
  ) then
    alter table public.sorting_mop_production_batches
      add constraint sorting_mop_production_cancellation_kind_check
      check (cancellation_kind is null or cancellation_kind in ('CORRECTED','CANCELLED'));
  end if;
end;
$$;

create index if not exists sorting_mop_production_flow_revision_idx
  on public.sorting_mop_production_batches(production_flow_item_id,revision_no desc,recorded_at desc);

create index if not exists sorting_mop_production_supersedes_idx
  on public.sorting_mop_production_batches(supersedes_mop_production_batch_id)
  where supersedes_mop_production_batch_id is not null;

-- Direct browser access remains private.
alter table public.sorting_mop_production_batches enable row level security;
revoke all on table public.sorting_mop_production_batches,
  public.sorting_mop_production_lines,
  public.sorting_mop_production_trolleys,
  public.production_flow_external_batches
  from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- 2. Keep reprocessing after cancellation in the same revision chain.
-- ---------------------------------------------------------------------

create or replace function public.sorting_mop_assign_revision_on_insert()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_previous public.sorting_mop_production_batches%rowtype;
begin
  -- Explicit correction inserts already supply their predecessor/revision.
  if new.supersedes_mop_production_batch_id is not null or coalesce(new.revision_no,1)>1 then
    return new;
  end if;

  select * into v_previous
  from public.sorting_mop_production_batches mb
  where mb.production_flow_item_id=new.production_flow_item_id
  order by mb.revision_no desc,coalesce(mb.cancelled_at,mb.recorded_at) desc,mb.mop_production_batch_id desc
  limit 1;

  if found and v_previous.status='CANCELLED' then
    new.supersedes_mop_production_batch_id:=v_previous.mop_production_batch_id;
    new.revision_no:=coalesce(v_previous.revision_no,1)+1;
    new.change_reason:=coalesce(new.change_reason,'Reprocessed after prior cancellation');
  else
    new.revision_no:=coalesce(new.revision_no,1);
  end if;

  return new;
end;
$$;

revoke all on function public.sorting_mop_assign_revision_on_insert()
  from public,anon,authenticated;

drop trigger if exists sorting_mop_assign_revision_before_insert
  on public.sorting_mop_production_batches;
create trigger sorting_mop_assign_revision_before_insert
before insert on public.sorting_mop_production_batches
for each row
execute function public.sorting_mop_assign_revision_on_insert();

-- ---------------------------------------------------------------------
-- 3. Controlled correction context.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_mop_production_correction_context(
  p_mop_production_batch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_lines jsonb:='[]'::jsonb;
  v_variants jsonb:='[]'::jsonb;
  v_trolleys jsonb:='[]'::jsonb;
  v_abs jsonb:='[]'::jsonb;
  v_history jsonb:='[]'::jsonb;
  v_live_trolley_locked boolean:=false;
  v_cancel_block_reason text;
begin
  perform public.require_sorting_operational_access();

  select * into v_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id;

  if not found then
    raise exception using errcode='P0002',message='MOP Production batch was not found.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_batch.production_flow_item_id;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='Correction context requires a MOP Production Flow item.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_line_id',ml.mop_production_line_id,
    'product_variant_id',ml.product_variant_id,
    'variant_code',ml.variant_code_snapshot,
    'variant_name',ml.variant_name_snapshot,
    'weight_kg',ml.weight_kg,
    'units',ml.units,
    'unit_weight_grams',ml.unit_weight_grams_snapshot
  ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb)
  into v_lines
  from public.sorting_mop_production_lines ml
  where ml.mop_production_batch_id=v_batch.mop_production_batch_id;

  if v_flow.source_schedule_product_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'product_variant_id',pv.product_variant_id,
      'variant_code',pv.variant_code,
      'display_name',pv.display_name,
      'unit_weight_grams',case
        when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
          then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
        else null
      end,
      'image_url',nullif(coalesce(pv.metadata->>'image_url',pv.metadata->>'photo_url',''),''),
      'active',pv.active
    ) order by pv.sort_order,pv.display_name,pv.variant_code),'[]'::jsonb)
    into v_variants
    from public.customer_schedule_product_variants spv
    join public.product_variants pv on pv.product_variant_id=spv.product_variant_id
    join public.product_types pt on pt.product_type_id=pv.product_type_id
    where spv.schedule_product_id=v_flow.source_schedule_product_id
      and pv.deleted_at is null
      and pt.deleted_at is null
      and pt.product_code='MOP';
  end if;

  if jsonb_array_length(v_variants)=0 then
    v_variants:=jsonb_build_array(jsonb_build_object(
      'product_variant_id',null,
      'variant_code','MOP_TOTAL',
      'display_name','MOP total',
      'unit_weight_grams',null,
      'image_url',null,
      'active',true,
      'generic',true
    ));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trolley_code',mt.trolley_code_snapshot,
    'trolley_id',mt.trolley_id,
    'stay_id',mt.stay_id,
    'lifecycle_action',mt.lifecycle_action
  ) order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb),
  coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false)
  into v_trolleys,v_live_trolley_locked
  from public.sorting_mop_production_trolleys mt
  where mt.mop_production_batch_id=v_batch.mop_production_batch_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'external_batch_id',b.production_flow_external_batch_id,
    'batch_reference',b.batch_reference,
    'quantity',b.quantity,
    'unit_code',b.unit_code,
    'capture_source',b.capture_source,
    'status',b.status,
    'recorded_at',b.recorded_at,
    'recorded_by_staff_id',b.recorded_by_staff_id,
    'recorded_by_name',sm.display_name,
    'notes',b.notes
  ) order by b.recorded_at desc,b.production_flow_external_batch_id desc),'[]'::jsonb)
  into v_abs
  from public.production_flow_external_batches b
  left join public.staff_members sm on sm.staff_id=b.recorded_by_staff_id
  where b.production_flow_item_id=v_batch.production_flow_item_id
    and b.external_system_code='ABS'
    and b.status='ACTIVE';

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_batch_id',h.mop_production_batch_id,
    'revision_no',h.revision_no,
    'status',h.status,
    'total_kg',h.total_weight_kg,
    'total_units',h.total_units,
    'recorded_at',h.recorded_at,
    'recorded_by_name',rec.display_name,
    'change_reason',h.change_reason,
    'cancellation_kind',h.cancellation_kind,
    'cancellation_reason',h.cancellation_reason,
    'cancelled_at',h.cancelled_at,
    'cancelled_by_name',can.display_name
  ) order by h.revision_no desc,h.recorded_at desc),'[]'::jsonb)
  into v_history
  from public.sorting_mop_production_batches h
  left join public.staff_members rec on rec.staff_id=h.recorded_by_staff_id
  left join public.staff_members can on can.staff_id=h.cancelled_by_staff_id
  where h.production_flow_item_id=v_batch.production_flow_item_id;

  if v_live_trolley_locked then
    v_cancel_block_reason:='This production owns live physical trolley lifecycle evidence. Use correction for MOP quantities/types. Full cancellation requires Trolley Control review so custody is not falsified.';
  end if;

  return jsonb_build_object(
    'batch',jsonb_build_object(
      'mop_production_batch_id',v_batch.mop_production_batch_id,
      'production_flow_item_id',v_batch.production_flow_item_id,
      'customer_id',v_batch.customer_id,
      'customer_name',v_batch.customer_name_snapshot,
      'business_date',v_batch.business_date,
      'scheduled_for_date',v_batch.scheduled_for_date,
      'delivery_due_date',v_batch.delivery_due_date,
      'operator_staff_id',v_batch.operator_staff_id,
      'entry_mode',v_batch.entry_mode,
      'physical_processed_on',v_batch.physical_processed_on,
      'physical_processed_time',v_batch.physical_processed_time,
      'physical_time_precision',v_batch.physical_time_precision,
      'total_kg',v_batch.total_weight_kg,
      'total_units',v_batch.total_units,
      'trolley_capture_status',v_batch.trolley_capture_status,
      'planned_output_trolley_quantity',v_batch.planned_output_trolley_quantity,
      'notes',v_batch.notes,
      'status',v_batch.status,
      'revision_no',v_batch.revision_no,
      'change_reason',v_batch.change_reason,
      'cancellation_kind',v_batch.cancellation_kind,
      'cancellation_reason',v_batch.cancellation_reason
    ),
    'flow',jsonb_build_object(
      'route_code',v_flow.route_code_snapshot,
      'route_display_name',v_flow.route_display_name_snapshot,
      'route_color',v_flow.route_color_snapshot,
      'source_schedule_product_id',v_flow.source_schedule_product_id
    ),
    'lines',v_lines,
    'available_variants',v_variants,
    'trolleys',v_trolleys,
    'live_trolley_locked',v_live_trolley_locked,
    'late_trolley_reference_editable',v_batch.entry_mode='LATE_RECONCILIATION',
    'active_abs_batches',v_abs,
    'revision_history',v_history,
    'can_correct',v_batch.status='RECORDED',
    'can_cancel',v_batch.status='RECORDED' and not v_live_trolley_locked,
    'cancel_block_reason',v_cancel_block_reason,
    'correction_contract','APPEND_ONLY_REPLACEMENT'
  );
end;
$$;

revoke all on function public.get_sorting_mop_production_correction_context(uuid)
  from public,anon,authenticated;
grant execute on function public.get_sorting_mop_production_correction_context(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- 4. Correct active MOP Production by creating a replacement revision.
-- ---------------------------------------------------------------------

create or replace function public.correct_sorting_mop_production(
  p_mop_production_batch_id uuid,
  p_reason text,
  p_lines jsonb,
  p_notes text default null,
  p_trolley_codes text[] default null,
  p_trolley_unknown boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.sorting_mop_production_batches%rowtype;
  v_new public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_actor_staff_id uuid:=public.current_staff_id();
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_notes text:=nullif(trim(coalesce(p_notes,'')),'');
  v_line record;
  v_variant uuid;
  v_variant_code text;
  v_variant_name text;
  v_unit_grams numeric;
  v_kg numeric;
  v_units integer;
  v_total_kg numeric:=0;
  v_total_units integer:=0;
  v_line_count integer:=0;
  v_normalized_lines jsonb:='[]'::jsonb;
  v_seen_keys text[]:=array[]::text[];
  v_variant_key text;
  v_old_trolley_codes text[]:=array[]::text[];
  v_new_trolley_codes text[]:=array[]::text[];
  v_old_live_trolley boolean:=false;
  v_trolley_unknown boolean:=false;
  v_trolley_status text;
  v_code text;
  v_old_trolley record;
  v_abs_count integer:=0;
  v_abs_old public.production_flow_external_batches%rowtype;
  v_abs_new public.production_flow_external_batches%rowtype;
  v_new_abs_quantity numeric;
  v_new_abs_unit text;
  v_abs_synced boolean:=false;
begin
  perform public.require_sorting_operational_access();

  if v_reason is null or length(v_reason)<5 then
    raise exception using errcode='22023',message='Correction reason must contain at least 5 characters.';
  end if;
  if length(v_reason)>1000 then
    raise exception using errcode='22023',message='Correction reason must be 1000 characters or fewer.';
  end if;
  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023',message='MOP notes must be 1000 characters or fewer.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023',message='Enter KG or Units for at least one MOP type.';
  end if;

  select * into v_old
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002',message='Only the current active MOP Production revision can be corrected.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_old.production_flow_item_id
  for update;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='MOP Production correction requires an exact MOP Production Flow item.';
  end if;

  -- Server-authoritative line normalization. Browser names/weights are never trusted.
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_variant:=nullif(v_line.value->>'product_variant_id','')::uuid;
    if v_variant is not null then
      select pv.variant_code,pv.display_name,
        case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end
      into v_variant_code,v_variant_name,v_unit_grams
      from public.product_variants pv
      join public.product_types pt on pt.product_type_id=pv.product_type_id
      where pv.product_variant_id=v_variant
        and pv.active=true and pv.deleted_at is null
        and pt.active=true and pt.deleted_at is null and pt.product_code='MOP';

      if not found then
        raise exception using errcode='22023',message='Selected MOP variant is not active MOP master data.';
      end if;

      if v_flow.source_schedule_product_id is not null and not exists(
        select 1 from public.customer_schedule_product_variants spv
        where spv.schedule_product_id=v_flow.source_schedule_product_id
          and spv.product_variant_id=v_variant
      ) then
        raise exception using errcode='22023',message=format('MOP variant %s is not linked to the original published Customer Schedule product.',v_variant_name);
      end if;
      v_variant_key:=v_variant::text;
    else
      -- Generic MOP total is only valid when the original published schedule product
      -- has no explicit MOP variant mapping. Do not let a crafted browser payload erase
      -- schedule-authoritative type identity.
      if v_flow.source_schedule_product_id is not null and exists(
        select 1
        from public.customer_schedule_product_variants spv
        join public.product_variants pv on pv.product_variant_id=spv.product_variant_id
        join public.product_types pt on pt.product_type_id=pv.product_type_id
        where spv.schedule_product_id=v_flow.source_schedule_product_id
          and pv.deleted_at is null
          and pt.deleted_at is null
          and pt.product_code='MOP'
      ) then
        raise exception using errcode='22023',message='Generic MOP total cannot replace MOP types linked to the original published Customer Schedule.';
      end if;
      v_variant_code:='MOP_TOTAL';
      v_variant_name:='MOP total';
      v_unit_grams:=null;
      v_variant_key:='MOP_TOTAL';
    end if;

    if v_variant_key=any(v_seen_keys) then
      raise exception using errcode='22023',message=format('MOP type %s was submitted more than once.',v_variant_name);
    end if;
    v_seen_keys:=array_append(v_seen_keys,v_variant_key);

    v_kg:=case when coalesce(v_line.value->>'weight_kg','') ~ '^[0-9]+([.][0-9]+)?$' then (v_line.value->>'weight_kg')::numeric else 0 end;
    v_units:=case when coalesce(v_line.value->>'units','') ~ '^[0-9]+$' then (v_line.value->>'units')::integer else 0 end;
    if v_kg<=0 and v_units>0 and coalesce(v_unit_grams,0)>0 then v_kg:=round((v_units*v_unit_grams/1000.0)::numeric,3); end if;
    if v_units<=0 and v_kg>0 and coalesce(v_unit_grams,0)>0 then v_units:=round(v_kg*1000.0/v_unit_grams)::integer; end if;
    if v_kg<=0 and v_units<=0 then continue; end if;

    v_total_kg:=v_total_kg+greatest(v_kg,0);
    v_total_units:=v_total_units+greatest(v_units,0);
    v_line_count:=v_line_count+1;
    v_normalized_lines:=v_normalized_lines || jsonb_build_array(jsonb_build_object(
      'product_variant_id',v_variant,
      'variant_code',v_variant_code,
      'variant_name',v_variant_name,
      'weight_kg',nullif(v_kg,0),
      'units',nullif(v_units,0),
      'unit_weight_grams',v_unit_grams
    ));
  end loop;

  if v_line_count=0 or (v_total_kg<=0 and v_total_units<=0) then
    raise exception using errcode='22023',message='Enter KG or Units for at least one MOP type.';
  end if;

  select coalesce(array_agg(mt.trolley_code_snapshot order by mt.trolley_code_snapshot),array[]::text[]),
         coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false)
  into v_old_trolley_codes,v_old_live_trolley
  from public.sorting_mop_production_trolleys mt
  where mt.mop_production_batch_id=v_old.mop_production_batch_id;

  if p_trolley_codes is null then
    v_new_trolley_codes:=v_old_trolley_codes;
  else
    select coalesce(array_agg(code order by code),array[]::text[])
    into v_new_trolley_codes
    from (
      select distinct upper(trim(x)) as code
      from unnest(coalesce(p_trolley_codes,array[]::text[])) x
      where nullif(trim(x),'') is not null
    ) q;
  end if;

  if exists(select 1 from unnest(v_new_trolley_codes) x where x !~ '^T[0-9]{1,10}T$') then
    raise exception using errcode='22023',message='Invalid trolley code in MOP Production correction.';
  end if;

  v_trolley_unknown:=coalesce(p_trolley_unknown,v_old.trolley_capture_status='UNKNOWN_LATE_ENTRY');

  if v_old.entry_mode='LIVE' then
    if v_trolley_unknown then
      raise exception using errcode='22023',message='Unknown trolley cannot replace live physical trolley lifecycle evidence.';
    end if;
    if v_new_trolley_codes is distinct from v_old_trolley_codes then
      raise exception using errcode='22023',message='Live trolley codes are lifecycle evidence and cannot be changed in MOP Production correction. Use Trolley Control review for a wrong physical trolley.';
    end if;
    v_trolley_status:=v_old.trolley_capture_status;
  else
    if v_trolley_unknown and cardinality(v_new_trolley_codes)>0 then
      raise exception using errcode='22023',message='Choose known late trolley references or Trolley number unavailable, not both.';
    end if;
    if v_trolley_unknown and v_old.planned_output_trolley_quantity>0 then v_trolley_status:='UNKNOWN_LATE_ENTRY';
    elsif cardinality(v_new_trolley_codes)>0 then v_trolley_status:='LATE_RECORDED_CODE';
    elsif v_old.planned_output_trolley_quantity=0 then v_trolley_status:='NOT_REQUIRED';
    else v_trolley_status:='UNKNOWN_LATE_ENTRY'; end if;
  end if;

  -- Supersede original evidence first; the whole transaction rolls back on any later error.
  update public.sorting_mop_production_batches
  set status='CANCELLED',
      cancellation_kind='CORRECTED',
      cancellation_reason=v_reason,
      cancelled_at=now(),
      cancelled_by_staff_id=v_actor_staff_id,
      cancelled_by_auth_user_id=auth.uid()
  where mop_production_batch_id=v_old.mop_production_batch_id;

  insert into public.sorting_mop_production_batches(
    production_flow_item_id,customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,shift_id,shift_code_snapshot,scheduled_for_date,delivery_due_date,
    operator_staff_id,entry_mode,physical_processed_on,physical_processed_time,physical_time_precision,
    total_weight_kg,total_units,trolley_capture_status,planned_output_trolley_quantity,
    recorded_by_staff_id,recorded_by_auth_user_id,notes,status,
    supersedes_mop_production_batch_id,revision_no,change_reason
  ) values (
    v_old.production_flow_item_id,v_old.customer_id,v_old.customer_code_snapshot,v_old.customer_name_snapshot,
    v_old.business_date,v_old.shift_id,v_old.shift_code_snapshot,v_old.scheduled_for_date,v_old.delivery_due_date,
    v_old.operator_staff_id,v_old.entry_mode,v_old.physical_processed_on,v_old.physical_processed_time,v_old.physical_time_precision,
    round(v_total_kg,3),v_total_units,v_trolley_status,v_old.planned_output_trolley_quantity,
    v_actor_staff_id,auth.uid(),v_notes,'RECORDED',
    v_old.mop_production_batch_id,coalesce(v_old.revision_no,1)+1,v_reason
  ) returning * into v_new;

  for v_line in select value from jsonb_array_elements(v_normalized_lines)
  loop
    insert into public.sorting_mop_production_lines(
      mop_production_batch_id,product_variant_id,variant_code_snapshot,variant_name_snapshot,
      weight_kg,units,unit_weight_grams_snapshot
    ) values(
      v_new.mop_production_batch_id,
      nullif(v_line.value->>'product_variant_id','')::uuid,
      v_line.value->>'variant_code',v_line.value->>'variant_name',
      nullif(v_line.value->>'weight_kg','')::numeric,
      nullif(v_line.value->>'units','')::integer,
      nullif(v_line.value->>'unit_weight_grams','')::numeric
    );
  end loop;

  if v_old.entry_mode='LIVE' then
    for v_old_trolley in
      select * from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=v_old.mop_production_batch_id
      order by mt.created_at,mt.mop_production_trolley_id
    loop
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_new.mop_production_batch_id,v_old_trolley.trolley_id,v_old_trolley.trolley_code_snapshot,
        v_old_trolley.stay_id,v_old_trolley.lifecycle_action
      );
    end loop;
  else
    foreach v_code in array v_new_trolley_codes
    loop
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_new.mop_production_batch_id,
        (select t.trolley_id from public.trolleys t where upper(t.trolley_code)=v_code and t.deleted_at is null limit 1),
        v_code,null,'LATE_REFERENCE_ONLY'
      );
    end loop;
  end if;

  -- The MOP ABS quantity is local trace evidence derived from recorded MOP Production.
  -- If exactly one active ABS record exists and the corrected total changed, supersede
  -- that local evidence with the same batch reference and corrected quantity.
  select count(*)::integer into v_abs_count
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_old.production_flow_item_id
    and b.external_system_code='ABS' and b.status='ACTIVE';

  if v_total_kg>0 then
    v_new_abs_quantity:=round(v_total_kg,2);
    v_new_abs_unit:='KG';
  else
    v_new_abs_quantity:=v_total_units;
    v_new_abs_unit:='UNIT';
  end if;

  if v_abs_count>1 then
    raise exception using errcode='23505',message='Multiple active ABS batches are linked to this Production Flow. Manager review is required before MOP Production can be corrected.';
  elsif v_abs_count=1 then
    select * into v_abs_old
    from public.production_flow_external_batches b
    where b.production_flow_item_id=v_old.production_flow_item_id
      and b.external_system_code='ABS' and b.status='ACTIVE'
    order by b.recorded_at desc,b.production_flow_external_batch_id desc
    limit 1
    for update;

    if v_abs_old.quantity is distinct from v_new_abs_quantity or v_abs_old.unit_code is distinct from v_new_abs_unit then
      if v_abs_old.capture_source='INTEGRATION' then
        raise exception using errcode='22023',message='Integrated ABS evidence cannot be changed from MOP Production correction. Correct the external integration source first.';
      end if;
      update public.production_flow_external_batches
      set status='SUPERSEDED',correction_reason=v_reason,cancelled_at=now(),
          cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
      where production_flow_external_batch_id=v_abs_old.production_flow_external_batch_id;

      insert into public.production_flow_external_batches(
        production_flow_item_id,external_system_code,batch_reference,quantity,unit_code,
        capture_source,status,supersedes_external_batch_id,notes,correction_reason,
        integration_metadata,recorded_by_staff_id,recorded_by_auth_user_id
      ) values (
        v_abs_old.production_flow_item_id,v_abs_old.external_system_code,v_abs_old.batch_reference,
        v_new_abs_quantity,v_new_abs_unit,v_abs_old.capture_source,'ACTIVE',
        v_abs_old.production_flow_external_batch_id,v_abs_old.notes,v_reason,
        coalesce(v_abs_old.integration_metadata,'{}'::jsonb) || jsonb_build_object(
          'mop_production_revision_sync',true,
          'source_mop_production_batch_id',v_new.mop_production_batch_id
        ),
        v_actor_staff_id,auth.uid()
      ) returning * into v_abs_new;

      v_abs_synced:=true;

      perform public.append_production_flow_event(
        v_old.production_flow_item_id,'ABS_BATCH_CORRECTED','PRODUCTION',40,'MOP',
        v_old.business_date,v_abs_new.recorded_at,v_actor_staff_id,v_actor_staff_id,auth.uid(),
        'SORTING_MOP_PRODUCTION','production_flow_external_batches',v_abs_new.production_flow_external_batch_id::text,
        jsonb_build_object(
          'old_external_batch_id',v_abs_old.production_flow_external_batch_id,
          'batch_reference',v_abs_new.batch_reference,
          'old_quantity',v_abs_old.quantity,'old_unit_code',v_abs_old.unit_code,
          'quantity',v_abs_new.quantity,'unit_code',v_abs_new.unit_code,
          'reason',v_reason,'source','MOP_PRODUCTION_CORRECTION'
        )
      );

      insert into public.audit_log(
        actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
        old_data,new_data,reason,source_application
      ) values(
        auth.uid(),v_actor_staff_id,'MOP_CORRECTION_SYNC_ABS_EVIDENCE','production_flow_external_batches',
        v_abs_new.production_flow_external_batch_id::text,to_jsonb(v_abs_old),to_jsonb(v_abs_new),
        v_reason,'SORTING_MOP_PRODUCTION'
      );
    end if;
  end if;

  perform public.append_production_flow_event(
    v_old.production_flow_item_id,'MOP_PRODUCTION_CORRECTED','PRODUCTION',40,'MOP',
    v_old.business_date,now(),v_old.operator_staff_id,v_actor_staff_id,auth.uid(),
    'SORTING_MOP_PRODUCTION','sorting_mop_production_batches',v_new.mop_production_batch_id::text,
    jsonb_build_object(
      'supersedes_mop_production_batch_id',v_old.mop_production_batch_id,
      'revision_no',v_new.revision_no,
      'old_total_kg',v_old.total_weight_kg,'old_total_units',v_old.total_units,
      'total_kg',v_new.total_weight_kg,'total_units',v_new.total_units,
      'trolley_capture_status',v_new.trolley_capture_status,
      'trolley_codes',to_jsonb(v_new_trolley_codes),
      'live_trolley_lifecycle_preserved',v_old.entry_mode='LIVE',
      'abs_evidence_synced',v_abs_synced,
      'reason',v_reason
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    old_data,new_data,reason,source_application
  ) values(
    auth.uid(),v_actor_staff_id,'CORRECT_SORTING_MOP_PRODUCTION','sorting_mop_production_batches',
    v_new.mop_production_batch_id::text,to_jsonb(v_old),to_jsonb(v_new),v_reason,'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'status','success',
    'mop_production_batch_id',v_new.mop_production_batch_id,
    'supersedes_mop_production_batch_id',v_old.mop_production_batch_id,
    'production_flow_item_id',v_new.production_flow_item_id,
    'revision_no',v_new.revision_no,
    'total_kg',v_new.total_weight_kg,
    'total_units',v_new.total_units,
    'trolley_capture_status',v_new.trolley_capture_status,
    'abs_evidence_synced',v_abs_synced,
    'message',format('MOP Production corrected as revision %s. Original evidence was preserved.',v_new.revision_no)
  );
end;
$$;

revoke all on function public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)
  from public,anon,authenticated;
grant execute on function public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- 5. Cancel current MOP Production when it is safe to return to queue.
-- ---------------------------------------------------------------------

create or replace function public.cancel_sorting_mop_production(
  p_mop_production_batch_id uuid,
  p_reason text,
  p_cancel_abs_evidence boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_batch public.sorting_mop_production_batches%rowtype;
  v_actor_staff_id uuid:=public.current_staff_id();
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_abs record;
  v_abs_count integer:=0;
  v_old_data jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_reason is null or length(v_reason)<5 then
    raise exception using errcode='22023',message='Cancellation reason must contain at least 5 characters.';
  end if;
  if length(v_reason)>1000 then
    raise exception using errcode='22023',message='Cancellation reason must be 1000 characters or fewer.';
  end if;

  select * into v_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002',message='Only the current active MOP Production revision can be cancelled.';
  end if;
  v_old_data:=to_jsonb(v_batch);

  if exists(
    select 1 from public.sorting_mop_production_trolleys mt
    where mt.mop_production_batch_id=v_batch.mop_production_batch_id
      and mt.lifecycle_action='LIVE_ASSIGNMENT'
  ) then
    raise exception using
      errcode='22023',
      message='Cancellation is blocked because this production owns live physical trolley lifecycle evidence. Correct MOP quantities/types here; a wrong trolley/customer assignment requires Trolley Control review.';
  end if;

  select count(*)::integer into v_abs_count
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_batch.production_flow_item_id
    and b.external_system_code='ABS' and b.status='ACTIVE';

  if v_abs_count>1 then
    raise exception using errcode='23505',message='Multiple active ABS batches are linked to this Production Flow. Manager review is required before MOP Production can be cancelled.';
  end if;

  if exists(
    select 1 from public.production_flow_external_batches b
    where b.production_flow_item_id=v_batch.production_flow_item_id
      and b.external_system_code='ABS' and b.status='ACTIVE'
      and b.capture_source='INTEGRATION'
  ) then
    raise exception using errcode='22023',message='Integrated ABS evidence is active for this MOP Production and cannot be cancelled from Sorting. Correct the integration source first.';
  end if;

  if v_abs_count>0 and not coalesce(p_cancel_abs_evidence,false) then
    raise exception using
      errcode='22023',
      message='This MOP Production has active ABS evidence. Confirm cancellation of the linked ElisCaretex ABS trace before cancelling the production record.';
  end if;

  if v_abs_count>0 then
    for v_abs in
      select b.* from public.production_flow_external_batches b
      where b.production_flow_item_id=v_batch.production_flow_item_id
        and b.external_system_code='ABS' and b.status='ACTIVE'
      order by b.recorded_at,b.production_flow_external_batch_id
      for update
    loop
      update public.production_flow_external_batches
      set status='CANCELLED',correction_reason=v_reason,cancelled_at=now(),
          cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
      where production_flow_external_batch_id=v_abs.production_flow_external_batch_id;

      perform public.append_production_flow_event(
        v_batch.production_flow_item_id,'ABS_BATCH_CANCELLED','PRODUCTION',40,'MOP',
        v_batch.business_date,now(),v_actor_staff_id,v_actor_staff_id,auth.uid(),
        'SORTING_MOP_PRODUCTION','production_flow_external_batches',v_abs.production_flow_external_batch_id::text,
        jsonb_build_object(
          'batch_reference',v_abs.batch_reference,'quantity',v_abs.quantity,'unit_code',v_abs.unit_code,
          'reason',v_reason,'source','MOP_PRODUCTION_CANCELLATION',
          'external_system_not_modified',true
        )
      );

      insert into public.audit_log(
        actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
        old_data,new_data,reason,source_application
      ) values(
        auth.uid(),v_actor_staff_id,'MOP_CANCELLATION_CANCEL_ABS_EVIDENCE','production_flow_external_batches',
        v_abs.production_flow_external_batch_id::text,to_jsonb(v_abs),
        (select to_jsonb(b) from public.production_flow_external_batches b where b.production_flow_external_batch_id=v_abs.production_flow_external_batch_id),
        v_reason,'SORTING_MOP_PRODUCTION'
      );
    end loop;
  end if;

  update public.sorting_mop_production_batches
  set status='CANCELLED',cancellation_kind='CANCELLED',cancellation_reason=v_reason,
      cancelled_at=now(),cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
  where mop_production_batch_id=v_batch.mop_production_batch_id
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_batch.production_flow_item_id,'MOP_PRODUCTION_CANCELLED','PRODUCTION',40,'MOP',
    v_batch.business_date,coalesce(v_batch.cancelled_at,now()),v_batch.operator_staff_id,v_actor_staff_id,auth.uid(),
    'SORTING_MOP_PRODUCTION','sorting_mop_production_batches',v_batch.mop_production_batch_id::text,
    jsonb_build_object(
      'revision_no',v_batch.revision_no,'total_kg',v_batch.total_weight_kg,'total_units',v_batch.total_units,
      'reason',v_reason,'linked_abs_evidence_cancelled',v_abs_count>0,
      'returns_to_mop_queue',true
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    old_data,new_data,reason,source_application
  ) values(
    auth.uid(),v_actor_staff_id,'CANCEL_SORTING_MOP_PRODUCTION','sorting_mop_production_batches',
    v_batch.mop_production_batch_id::text,v_old_data,to_jsonb(v_batch),v_reason,'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'status','success','mop_production_batch_id',v_batch.mop_production_batch_id,
    'production_flow_item_id',v_batch.production_flow_item_id,'revision_no',v_batch.revision_no,
    'abs_evidence_cancelled',v_abs_count>0,'returns_to_queue',true,
    'message','MOP Production cancelled. Original evidence remains in Trace history and the washed customer can return to the MOP queue.'
  );
end;
$$;

revoke all on function public.cancel_sorting_mop_production(uuid,text,boolean)
  from public,anon,authenticated;
grant execute on function public.cancel_sorting_mop_production(uuid,text,boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- 6. Trace read model: active revision or latest cancellation per Flow.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_mop_recent_trace(
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb:='[]'::jsonb;
  v_pending integer:=0;
  v_posted integer:=0;
  v_cancelled integer:=0;
begin
  perform public.require_sorting_operational_access();

  with flow_activity as (
    select mb.production_flow_item_id,
           max(coalesce(mb.cancelled_at,mb.recorded_at)) as activity_at
    from public.sorting_mop_production_batches mb
    group by mb.production_flow_item_id
    order by max(coalesce(mb.cancelled_at,mb.recorded_at)) desc,mb.production_flow_item_id
    limit v_limit
  ), selected as (
    select distinct on (mb.production_flow_item_id) mb.*
    from public.sorting_mop_production_batches mb
    join flow_activity fa on fa.production_flow_item_id=mb.production_flow_item_id
    order by mb.production_flow_item_id,
      case when mb.status='RECORDED' then 0 else 1 end,
      mb.revision_no desc,coalesce(mb.cancelled_at,mb.recorded_at) desc,mb.mop_production_batch_id desc
  ), trace_rows as (
    select
      mb.mop_production_batch_id,
      mb.production_flow_item_id,
      mb.customer_id,
      mb.customer_name_snapshot as customer_name,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,
      mb.business_date,mb.scheduled_for_date,mb.delivery_due_date,
      mb.operator_staff_id,sm.display_name as operator_name,
      mb.entry_mode,mb.physical_processed_on,mb.physical_processed_time,mb.physical_time_precision,
      mb.total_weight_kg as total_kg,mb.total_units,mb.trolley_capture_status,
      mb.planned_output_trolley_quantity,mb.recorded_at,mb.notes,mb.status,
      mb.revision_no,mb.supersedes_mop_production_batch_id,mb.change_reason,
      mb.cancellation_kind,mb.cancellation_reason,mb.cancelled_at,
      cancel_staff.display_name as cancelled_by_name,
      coalesce(lines.lines,'[]'::jsonb) as lines,
      coalesce(trolleys.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(abs_data.active_abs_batches,'[]'::jsonb) as active_abs_batches,
      coalesce(abs_data.abs_history_count,0)::integer as abs_history_count,
      coalesce(revisions.revision_history,'[]'::jsonb) as revision_history,
      coalesce(trolleys.live_trolley_locked,false) as live_trolley_locked,
      case
        when mb.status='CANCELLED' then 'CANCELLED'
        when coalesce(abs_data.active_abs_count,0)>0 then 'POSTED'
        else 'PENDING'
      end as abs_status
    from selected mb
    join public.production_flow_items pfi on pfi.production_flow_item_id=mb.production_flow_item_id
    left join public.staff_members sm on sm.staff_id=mb.operator_staff_id
    left join public.staff_members cancel_staff on cancel_staff.staff_id=mb.cancelled_by_staff_id
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',ml.product_variant_id,'variant_code',ml.variant_code_snapshot,
        'variant_name',ml.variant_name_snapshot,'weight_kg',ml.weight_kg,'units',ml.units,
        'unit_weight_grams',ml.unit_weight_grams_snapshot
      ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb) as lines
      from public.sorting_mop_production_lines ml
      where ml.mop_production_batch_id=mb.mop_production_batch_id
    ) lines on true
    left join lateral (
      select coalesce(jsonb_agg(mt.trolley_code_snapshot order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb) as trolley_codes,
             coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false) as live_trolley_locked
      from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=mb.mop_production_batch_id
    ) trolleys on true
    left join lateral (
      select count(*) filter(where b.status='ACTIVE')::integer as active_abs_count,
             count(*)::integer as abs_history_count,
             coalesce(jsonb_agg(jsonb_build_object(
               'external_batch_id',b.production_flow_external_batch_id,'batch_reference',b.batch_reference,
               'batch_number',b.batch_number,'batch_business_date',b.batch_business_date,
               'batch_week_start',b.batch_week_start,'quantity',b.quantity,'unit_code',b.unit_code,
               'capture_source',b.capture_source,'status',b.status,'recorded_at',b.recorded_at,
               'recorded_by_staff_id',b.recorded_by_staff_id,'recorded_by_name',abs_staff.display_name,
               'notes',b.notes,'supersedes_external_batch_id',b.supersedes_external_batch_id,
               'correction_reason',b.correction_reason,'cancelled_at',b.cancelled_at
             ) order by b.recorded_at desc,b.production_flow_external_batch_id desc)
             filter(where b.status='ACTIVE'),'[]'::jsonb) as active_abs_batches
      from public.production_flow_external_batches b
      left join public.staff_members abs_staff on abs_staff.staff_id=b.recorded_by_staff_id
      where b.production_flow_item_id=mb.production_flow_item_id and b.external_system_code='ABS'
    ) abs_data on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'mop_production_batch_id',h.mop_production_batch_id,'revision_no',h.revision_no,
        'status',h.status,'total_kg',h.total_weight_kg,'total_units',h.total_units,
        'recorded_at',h.recorded_at,'recorded_by_name',rec.display_name,
        'change_reason',h.change_reason,'cancellation_kind',h.cancellation_kind,
        'cancellation_reason',h.cancellation_reason,'cancelled_at',h.cancelled_at,
        'cancelled_by_name',can.display_name
      ) order by h.revision_no desc,h.recorded_at desc),'[]'::jsonb) as revision_history
      from public.sorting_mop_production_batches h
      left join public.staff_members rec on rec.staff_id=h.recorded_by_staff_id
      left join public.staff_members can on can.staff_id=h.cancelled_by_staff_id
      where h.production_flow_item_id=mb.production_flow_item_id
    ) revisions on true
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by coalesce(t.cancelled_at,t.recorded_at) desc,t.mop_production_batch_id desc),'[]'::jsonb),
         count(*) filter(where t.status='RECORDED' and t.abs_status='PENDING')::integer,
         count(*) filter(where t.status='RECORDED' and t.abs_status='POSTED')::integer,
         count(*) filter(where t.status='CANCELLED')::integer
  into v_rows,v_pending,v_posted,v_cancelled
  from trace_rows t;

  return jsonb_build_object(
    'rows',v_rows,'pending_abs_count',v_pending,'posted_abs_count',v_posted,
    'cancelled_count',v_cancelled,'limit',v_limit,
    'source','MOP_PRODUCTION_REVISION_TRACE_PLUS_SHARED_PRODUCTION_FLOW_ABS',
    'correction_contract','APPEND_ONLY_REPLACEMENT'
  );
end;
$$;

revoke all on function public.get_sorting_mop_recent_trace(integer)
  from public,anon,authenticated;
grant execute on function public.get_sorting_mop_recent_trace(integer)
  to authenticated;

comment on function public.get_sorting_mop_production_correction_context(uuid) is
  'Controlled MOP Production correction context. Returns original scheduled variants, current lines, trolley lifecycle lock, ABS evidence and revision history without exposing source tables.';
comment on function public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean) is
  'Append-only MOP Production correction. Supersedes the active batch with a new revision, preserves live trolley lifecycle, allows late-reference trolley correction, and synchronizes one active local ABS evidence quantity when needed.';
comment on function public.cancel_sorting_mop_production(uuid,text,boolean) is
  'Cancels current MOP Production only when physical trolley lifecycle does not require review. Linked ABS trace cancellation must be explicitly confirmed. Washing and Production Flow remain unchanged.';
comment on function public.get_sorting_mop_recent_trace(integer) is
  'Revision-aware MOP Production Trace with preserved route snapshots, current/cancelled production state, trolley evidence, correction history and shared ABS evidence.';

commit;
