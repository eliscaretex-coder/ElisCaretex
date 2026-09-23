-- ElisCaretex V2
-- Migration 031: Sorting MOP visual/master improvements + Washing reception exception
-- Status: PREPARED — owner-run SQL only. Do not mark APPLIED until owner evidence is returned.
--
-- Purpose
-- 1. Provide a controlled MOP Types read/update API for display name, unit weight,
--    notes and photo metadata. Photos are stored in Supabase Storage.
-- 2. Keep MOP type identity (product_variant_id / variant_code) stable.
-- 3. Add a controlled Washing Reception Exception path for genuinely missed
--    Reception evidence. The reason is mandatory and the exception is linked to
--    the final Wash ID in the same transaction.
-- 4. Preserve the normal gate: Reception evidence remains the default. An official
--    no-trolley customer should normally use record_sorting_non_trolley_arrival.
--
-- IMPORTANT STORAGE PRECONDITION
-- Create the public Storage bucket `mop-type-photos` in the Supabase Dashboard
-- before Validation 031. Configure max file size 2 MB and MIME types:
-- image/jpeg, image/png, image/webp.
-- This migration intentionally does NOT insert/update storage.buckets directly.

begin;

-- ---------------------------------------------------------------------
-- 1. Storage write policies for MOP type photos.
--    Public bucket serving handles reads by URL. These policies allow only
--    ADMIN/MANAGER to list/upload/update/delete objects via the Storage API.
-- ---------------------------------------------------------------------

drop policy if exists mop_type_photos_manager_select on storage.objects;
drop policy if exists mop_type_photos_manager_insert on storage.objects;
drop policy if exists mop_type_photos_manager_update on storage.objects;
drop policy if exists mop_type_photos_manager_delete on storage.objects;

create policy mop_type_photos_manager_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'mop-type-photos'
  and public.has_any_role(array['ADMIN','MANAGER'])
);

create policy mop_type_photos_manager_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'mop-type-photos'
  and public.has_any_role(array['ADMIN','MANAGER'])
);

create policy mop_type_photos_manager_update
on storage.objects
for update
to authenticated
using (
  bucket_id = 'mop-type-photos'
  and public.has_any_role(array['ADMIN','MANAGER'])
)
with check (
  bucket_id = 'mop-type-photos'
  and public.has_any_role(array['ADMIN','MANAGER'])
);

create policy mop_type_photos_manager_delete
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'mop-type-photos'
  and public.has_any_role(array['ADMIN','MANAGER'])
);

-- ---------------------------------------------------------------------
-- 2. Controlled MOP type catalog and update.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_mop_type_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_types jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_variant_id', pv.product_variant_id,
        'variant_code', pv.variant_code,
        'display_name', pv.display_name,
        'active', pv.active,
        'sort_order', pv.sort_order,
        'unit_weight_grams', case
          when coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams', '') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end,
        'image_url', nullif(coalesce(pv.metadata->>'image_url', pv.metadata->>'photo_url', ''), ''),
        'notes', nullif(coalesce(pv.metadata->>'notes', ''), ''),
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
  where pv.deleted_at is null;

  return jsonb_build_object(
    'bucket_id', 'mop-type-photos',
    'max_file_bytes', 2097152,
    'allowed_mime_types', jsonb_build_array('image/jpeg','image/png','image/webp'),
    'can_manage', public.has_any_role(array['ADMIN','MANAGER']),
    'types', v_types
  );
end;
$$;

revoke all on function public.get_sorting_mop_type_catalog()
  from public, anon, authenticated;
grant execute on function public.get_sorting_mop_type_catalog()
  to authenticated;

create or replace function public.update_sorting_mop_type_master(
  p_product_variant_id uuid,
  p_display_name text,
  p_unit_weight_grams numeric default null,
  p_notes text default null,
  p_image_url text default null,
  p_remove_image boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
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
  if not public.has_any_role(array['ADMIN','MANAGER']) then
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
$$;

revoke all on function public.update_sorting_mop_type_master(uuid,text,numeric,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.update_sorting_mop_type_master(uuid,text,numeric,text,text,boolean)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. Washing Reception Exception evidence.
-- ---------------------------------------------------------------------

create table if not exists public.sorting_wash_reception_exceptions (
  wash_reception_exception_id uuid primary key default gen_random_uuid(),
  wash_run_id uuid not null references public.sorting_wash_runs(wash_run_id) on delete restrict,
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text,
  customer_name_snapshot text not null,
  product_code text not null,
  source_schedule_product_id uuid references public.customer_schedule_products(schedule_product_id) on delete restrict,
  scheduled_for_date date,
  reason text not null,
  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  source_application text not null default 'SORTING_WASHING',
  metadata jsonb not null default '{}'::jsonb,
  constraint sorting_wash_reception_exception_product_check check (product_code in ('CLOTHES','MOP')),
  constraint sorting_wash_reception_exception_reason_check check (length(trim(reason)) between 5 and 500),
  constraint sorting_wash_reception_exception_schedule_pair_check check (
    (source_schedule_product_id is null and scheduled_for_date is null)
    or (source_schedule_product_id is not null and scheduled_for_date is not null)
  ),
  constraint sorting_wash_reception_exception_unique unique (wash_run_id, customer_id)
);

create index if not exists sorting_wash_reception_exceptions_daily_idx
  on public.sorting_wash_reception_exceptions(business_date, shift_id, recorded_at desc);
create index if not exists sorting_wash_reception_exceptions_customer_idx
  on public.sorting_wash_reception_exceptions(customer_id, recorded_at desc);

alter table public.sorting_wash_reception_exceptions enable row level security;
revoke all on table public.sorting_wash_reception_exceptions from public, anon, authenticated;

-- Private helper: true when the selected Washing item already has normal Reception
-- evidence (physical trolley CONTENTS or the controlled no-trolley arrival introduced
-- by Migration 030). Off-schedule items can only have physical trolley evidence.
create or replace function public.sorting_wash_selection_has_reception_evidence(
  p_business_date date,
  p_product_code text,
  p_customer_id uuid,
  p_schedule_product_id uuid,
  p_scheduled_for_date date
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_contents integer := 0;
  v_no_trolley integer := 0;
begin
  if p_customer_id is null then return false; end if;

  if p_schedule_product_id is not null and p_scheduled_for_date is not null then
    select count(*)::integer
    into v_contents
    from public.sorting_trolley_intake_products stip
    join public.sorting_trolley_intakes sti
      on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
    where sti.customer_id = p_customer_id
      and sti.contents_status = 'CONTENTS'
      and stip.product_code = p_product_code
      and stip.source_schedule_product_id = p_schedule_product_id
      and stip.scheduled_for_date = p_scheduled_for_date;

    select count(*)::integer
    into v_no_trolley
    from public.sorting_non_trolley_arrivals a
    where a.status = 'RECORDED'
      and a.customer_id = p_customer_id
      and a.product_code = p_product_code
      and a.source_schedule_product_id = p_schedule_product_id
      and a.scheduled_for_date = p_scheduled_for_date;
  else
    select count(*)::integer
    into v_contents
    from public.sorting_trolley_intake_products stip
    join public.sorting_trolley_intakes sti
      on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
    where sti.customer_id = p_customer_id
      and sti.contents_status = 'CONTENTS'
      and stip.product_code = p_product_code
      and sti.business_date = p_business_date;
  end if;

  return coalesce(v_contents,0) + coalesce(v_no_trolley,0) > 0;
end;
$$;

revoke all on function public.sorting_wash_selection_has_reception_evidence(date,text,uuid,uuid,date)
  from public, anon, authenticated;

-- Private gate. Any selected customer not covered by an explicit exception still
-- goes through Migration 030's authoritative normal Reception gate.
create or replace function public.sorting_assert_wash_reception_gate_v2(
  p_business_date date,
  p_wash_type text,
  p_customer_selections jsonb,
  p_reception_exceptions jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_selection record;
  v_exception record;
  v_regular jsonb := '[]'::jsonb;
  v_customer_id uuid;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_reason text;
  v_match_count integer;
  v_exceptions jsonb := coalesce(p_reception_exceptions,'[]'::jsonb);
begin
  if p_customer_selections is null
     or jsonb_typeof(p_customer_selections) <> 'array'
     or jsonb_array_length(p_customer_selections) = 0 then
    raise exception using errcode='22023', message='At least one customer selection is required.';
  end if;

  if jsonb_typeof(v_exceptions) <> 'array' then
    raise exception using errcode='22023', message='Reception exceptions must be an array.';
  end if;

  -- Every declared exception must match one exact selected customer/date/product row.
  for v_exception in select value from jsonb_array_elements(v_exceptions)
  loop
    v_customer_id := nullif(v_exception.value->>'customer_id','')::uuid;
    v_schedule_product_id := nullif(v_exception.value->>'schedule_product_id','')::uuid;
    v_scheduled_for_date := nullif(v_exception.value->>'scheduled_for_date','')::date;
    v_reason := trim(coalesce(v_exception.value->>'reason',''));

    if v_customer_id is null or length(v_reason) < 5 then
      raise exception using errcode='22023', message='Every Reception exception requires a customer and a meaningful reason.';
    end if;
    if length(v_reason) > 500 then
      raise exception using errcode='22023', message='Reception exception reason is too long.';
    end if;
    if (v_schedule_product_id is null) <> (v_scheduled_for_date is null) then
      raise exception using errcode='22023', message='Reception exception Scheduled Date and schedule product must be supplied together.';
    end if;

    select count(*)::integer
    into v_match_count
    from jsonb_array_elements(p_customer_selections) s
    where nullif(s.value->>'customer_id','')::uuid = v_customer_id
      and nullif(s.value->>'schedule_product_id','')::uuid is not distinct from v_schedule_product_id
      and nullif(s.value->>'scheduled_for_date','')::date is not distinct from v_scheduled_for_date;

    if v_match_count <> 1 then
      raise exception using errcode='22023', message='Reception exception must match exactly one selected Washing customer/date.';
    end if;
  end loop;

  -- Remove exception-covered rows and run the unchanged normal gate on the rest.
  for v_selection in select value from jsonb_array_elements(p_customer_selections)
  loop
    v_customer_id := nullif(v_selection.value->>'customer_id','')::uuid;
    v_schedule_product_id := nullif(v_selection.value->>'schedule_product_id','')::uuid;
    v_scheduled_for_date := nullif(v_selection.value->>'scheduled_for_date','')::date;

    if exists(
      select 1
      from jsonb_array_elements(v_exceptions) e
      where nullif(e.value->>'customer_id','')::uuid = v_customer_id
        and nullif(e.value->>'schedule_product_id','')::uuid is not distinct from v_schedule_product_id
        and nullif(e.value->>'scheduled_for_date','')::date is not distinct from v_scheduled_for_date
        and length(trim(coalesce(e.value->>'reason',''))) >= 5
    ) then
      continue;
    end if;

    v_regular := v_regular || jsonb_build_array(v_selection.value);
  end loop;

  if jsonb_array_length(v_regular) > 0 then
    perform public.sorting_assert_wash_scan_gate(p_business_date, p_wash_type, v_regular);
  end if;
end;
$$;

revoke all on function public.sorting_assert_wash_reception_gate_v2(date,text,jsonb,jsonb)
  from public, anon, authenticated;

-- Private writer. It records only exception rows that truly lacked normal Reception
-- evidence at save time, and links every exception to the final Wash ID.
create or replace function public.sorting_record_wash_reception_exceptions(
  p_wash_run_id uuid,
  p_reception_exceptions jsonb default '[]'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_wash public.sorting_wash_runs%rowtype;
  v_exception record;
  v_wrc public.sorting_wash_run_customers%rowtype;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_reason text;
  v_product_code text;
  v_actor_staff_id uuid := public.current_staff_id();
  v_row public.sorting_wash_reception_exceptions%rowtype;
  v_count integer := 0;
  v_exceptions jsonb := coalesce(p_reception_exceptions,'[]'::jsonb);
begin
  if jsonb_typeof(v_exceptions)<>'array' then
    raise exception using errcode='22023', message='Reception exceptions must be an array.';
  end if;
  if jsonb_array_length(v_exceptions)=0 then
    return 0;
  end if;

  select * into v_wash
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id;
  if not found then
    raise exception using errcode='P0002', message='Washing record was not found for Reception exception linkage.';
  end if;

  v_product_code := case when v_wash.wash_type='MOP' then 'MOP' else 'CLOTHES' end;

  for v_exception in select value from jsonb_array_elements(v_exceptions)
  loop
    v_schedule_product_id := nullif(v_exception.value->>'schedule_product_id','')::uuid;
    v_scheduled_for_date := nullif(v_exception.value->>'scheduled_for_date','')::date;
    v_reason := trim(coalesce(v_exception.value->>'reason',''));

    select * into v_wrc
    from public.sorting_wash_run_customers wrc
    where wrc.wash_run_id = p_wash_run_id
      and wrc.customer_id = nullif(v_exception.value->>'customer_id','')::uuid
      and wrc.source_schedule_product_id is not distinct from v_schedule_product_id
      and wrc.scheduled_for_date is not distinct from v_scheduled_for_date
    limit 1;

    if not found then
      raise exception using errcode='22023', message='Reception exception could not be linked to the saved Washing trace.';
    end if;

    -- If normal evidence exists by save time, do not fabricate an exception record.
    if public.sorting_wash_selection_has_reception_evidence(
      v_wash.business_date,
      v_product_code,
      v_wrc.customer_id,
      v_wrc.source_schedule_product_id,
      v_wrc.scheduled_for_date
    ) then
      continue;
    end if;

    insert into public.sorting_wash_reception_exceptions(
      wash_run_id,business_date,shift_id,shift_code_snapshot,operator_staff_id,
      customer_id,customer_code_snapshot,customer_name_snapshot,product_code,
      source_schedule_product_id,scheduled_for_date,reason,
      recorded_by_staff_id,recorded_by_auth_user_id,source_application,metadata
    ) values (
      v_wash.wash_run_id,v_wash.business_date,v_wash.shift_id,v_wash.shift_code_snapshot,v_wash.operator_staff_id,
      v_wrc.customer_id,v_wrc.customer_code_snapshot,v_wrc.customer_name_snapshot,v_product_code,
      v_wrc.source_schedule_product_id,v_wrc.scheduled_for_date,v_reason,
      v_actor_staff_id,auth.uid(),'SORTING_WASHING',jsonb_build_object(
        'exception_type','RECEPTION_EVIDENCE_MISSED',
        'wash_code',v_wash.wash_code,
        'wash_type',v_wash.wash_type
      )
    )
    returning * into v_row;

    insert into public.audit_log(
      actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
      new_data,reason,source_application
    ) values (
      auth.uid(),v_actor_staff_id,'SORTING_WASH_RECEPTION_EXCEPTION_RECORDED',
      'sorting_wash_reception_exceptions',v_row.wash_reception_exception_id::text,
      to_jsonb(v_row),v_reason,'SORTING_WASHING'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.sorting_record_wash_reception_exceptions(uuid,jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Browser-facing Washing V4 writes.
--    Normal rows still use Migration 030's gate. Exception rows require reason,
--    are validated before save, and are written atomically after the Wash ID exists.
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_wash_run_v4(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_reception_exceptions jsonb default '[]'::jsonb,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_result jsonb;
  v_exception_count integer;
begin
  perform public.require_sorting_operational_access();
  perform public.sorting_assert_wash_reception_gate_v2(v_business_date,p_wash_type,p_customer_selections,p_reception_exceptions);

  v_result := public.save_sorting_wash_run_v2(
    p_shift_code,p_washer_id,p_operator_staff_id,p_start_time,p_weight_kg,
    p_wash_type,p_customer_selections,p_notes
  );

  v_exception_count := public.sorting_record_wash_reception_exceptions(
    nullif(v_result->>'wash_run_id','')::uuid,
    p_reception_exceptions
  );

  return v_result || jsonb_build_object(
    'reception_exception_count',v_exception_count,
    'reception_exception_recorded',v_exception_count>0
  );
end;
$$;

create or replace function public.save_sorting_missed_wash_v4(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_reception_exceptions jsonb,
  p_notes text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_result jsonb;
  v_exception_count integer;
begin
  perform public.require_sorting_operational_access();
  perform public.sorting_assert_wash_reception_gate_v2(v_business_date,p_wash_type,p_customer_selections,p_reception_exceptions);

  v_result := public.save_sorting_missed_wash_v2(
    p_shift_code,p_washer_id,p_operator_staff_id,p_start_time,p_weight_kg,
    p_wash_type,p_customer_selections,p_notes,p_reason
  );

  v_exception_count := public.sorting_record_wash_reception_exceptions(
    nullif(v_result->>'wash_run_id','')::uuid,
    p_reception_exceptions
  );

  return v_result || jsonb_build_object(
    'reception_exception_count',v_exception_count,
    'reception_exception_recorded',v_exception_count>0
  );
end;
$$;

create or replace function public.correct_sorting_wash_run_v4(
  p_wash_run_id uuid,
  p_expected_row_version integer,
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_reception_exceptions jsonb,
  p_notes text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_old public.sorting_wash_runs%rowtype;
  v_old_keys text[];
  v_new_keys text[];
  v_result jsonb;
  v_exception_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  select * into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id=p_wash_run_id;
  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  select array_agg(key order by key) into v_old_keys
  from (
    select case
      when wrc.source_schedule_product_id is not null and wrc.scheduled_for_date is not null
        then 'S:'||wrc.source_schedule_product_id::text||':'||wrc.scheduled_for_date::text
      else 'U:'||wrc.customer_id::text end as key
    from public.sorting_wash_run_customers wrc
    where wrc.wash_run_id=p_wash_run_id
  ) q;

  select array_agg(key order by key) into v_new_keys
  from (
    select case
      when nullif(value->>'schedule_product_id','') is not null and nullif(value->>'scheduled_for_date','') is not null
        then 'S:'||(value->>'schedule_product_id')||':'||(value->>'scheduled_for_date')
      else 'U:'||(value->>'customer_id') end as key
    from jsonb_array_elements(coalesce(p_customer_selections,'[]'::jsonb))
  ) q;

  -- Preserve the legacy same-customer/date/type correction exception from V3.
  -- Any changed Customer/Date/Type uses the new normal-or-exception gate.
  if upper(trim(coalesce(p_wash_type,''))) <> v_old.wash_type
     or v_new_keys is distinct from v_old_keys then
    perform public.sorting_assert_wash_reception_gate_v2(
      v_business_date,p_wash_type,p_customer_selections,p_reception_exceptions
    );
  end if;

  v_result := public.correct_sorting_wash_run_v2(
    p_wash_run_id,p_expected_row_version,p_shift_code,p_washer_id,p_operator_staff_id,
    p_start_time,p_weight_kg,p_wash_type,p_customer_selections,p_notes,p_reason
  );

  if nullif(v_result->>'wash_run_id','') is not null then
    v_exception_count := public.sorting_record_wash_reception_exceptions(
      (v_result->>'wash_run_id')::uuid,
      p_reception_exceptions
    );
  end if;

  return v_result || jsonb_build_object(
    'reception_exception_count',v_exception_count,
    'reception_exception_recorded',v_exception_count>0
  );
end;
$$;

revoke all on function public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)
  from public, anon, authenticated;
revoke all on function public.correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)
  from public, anon, authenticated;

grant execute on function public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text)
  to authenticated;
grant execute on function public.save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)
  to authenticated;
grant execute on function public.correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)
  to authenticated;

comment on function public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text) is
  'Authoritative Washing V4 write. Normal Reception evidence is required unless an exact selected customer/date has a controlled reasoned Reception exception, which is linked to the final Wash ID.';

-- ---------------------------------------------------------------------
-- 5. Washing read model exposes exception evidence in recent history.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_washing_context_v4(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb := public.get_sorting_washing_context_v3(p_shift_code);
  v_recent jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(jsonb_agg(
    w.value || jsonb_build_object(
      'reception_exception_count',coalesce(ex.exception_count,0),
      'reception_exceptions',coalesce(ex.exceptions,'[]'::jsonb)
    )
    order by nullif(w.value->>'started_at','')::timestamptz desc nulls last
  ),'[]'::jsonb)
  into v_recent
  from jsonb_array_elements(coalesce(v_base->'recent_washes','[]'::jsonb)) w
  left join lateral (
    select count(*)::integer as exception_count,
           coalesce(jsonb_agg(jsonb_build_object(
             'wash_reception_exception_id',e.wash_reception_exception_id,
             'customer_id',e.customer_id,
             'customer_name',e.customer_name_snapshot,
             'product_code',e.product_code,
             'scheduled_for_date',e.scheduled_for_date,
             'reason',e.reason,
             'recorded_at',e.recorded_at
           ) order by e.recorded_at),'[]'::jsonb) as exceptions
    from public.sorting_wash_reception_exceptions e
    where e.wash_run_id=nullif(w.value->>'wash_run_id','')::uuid
  ) ex on true;

  return v_base || jsonb_build_object(
    'recent_washes',v_recent,
    'reception_exception_supported',true,
    'source','SORTING_WASHING_CONTEXT_V4'
  );
end;
$$;

revoke all on function public.get_sorting_washing_context_v4(text)
  from public, anon, authenticated;
grant execute on function public.get_sorting_washing_context_v4(text)
  to authenticated;

commit;
