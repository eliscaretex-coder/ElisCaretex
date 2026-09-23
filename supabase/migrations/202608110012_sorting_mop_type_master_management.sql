-- ElisCaretex V2
-- Migration 032: Sorting MOP Type Master Management
-- Status: PREPARED — owner-run SQL only.
--
-- Purpose
-- 1. Upgrade the existing MOP Types editor into a governed catalogue manager.
-- 2. Allow ADMIN/MANAGER to create new MOP product variants and maintain
--    display name, category, dry unit weight, notes, photo metadata and order.
-- 3. Keep variant_code permanent after creation so published schedules and
--    production history retain a stable identity.
-- 4. Preserve all existing rows. This migration does not delete or deactivate
--    product variants.
-- 5. Prefill verified legacy unit weights only where historical evidence is
--    consistent. Ambiguous observations remain review notes, never invented facts.
-- 6. Continue storing image files in the already configured public Storage
--    bucket `mop-type-photos`; the database stores only the public image URL.
--
-- IMPORTANT: This file must be executed by the project owner. ChatGPT must not
-- execute it against the project database.

begin;

-- ---------------------------------------------------------------------
-- 0. Legacy-informed MOP master prefill.
--
-- The current V2 catalogue identities already exist and must not be replaced.
-- Historical MOP production evidence was reviewed from the legacy system.
-- Only exact-name variants with one consistent observed unit weight are
-- prefilled here, and only when no unit weight is already configured.
--
-- Exact consistent observations:
--   CLEANING_CLOTHS   30 g  (10 legacy production records)
--   MANORHAMILTON    110 g  ( 3 legacy production records)
--   TWISTER_MOP      190 g  ( 3 legacy production records)
--   VELCRO_MOP       100 g  ( 7 legacy production records)
--   WHITE_MOP        170 g  ( 4 legacy production records)
--
-- STANDARD_POCKET_MOPS is deliberately NOT assigned an operational weight:
-- legacy history contains both 130 g (55 records) and 120 g (8 records).
-- That ambiguity is surfaced to the manager for review instead of guessing.
-- ---------------------------------------------------------------------

with verified_weight_seed(variant_code, weight_grams, evidence_count) as (
  values
    ('CLEANING_CLOTHS'::text,  30::numeric, 10::integer),
    ('MANORHAMILTON'::text,   110::numeric,  3::integer),
    ('TWISTER_MOP'::text,     190::numeric,  3::integer),
    ('VELCRO_MOP'::text,      100::numeric,  7::integer),
    ('WHITE_MOP'::text,       170::numeric,  4::integer)
)
update public.product_variants pv
set metadata = jsonb_set(
      jsonb_set(
        jsonb_set(
          coalesce(pv.metadata,'{}'::jsonb),
          '{unit_weight_grams}',
          to_jsonb(seed.weight_grams),
          true
        ),
        '{unit_weight_source}',
        to_jsonb('LEGACY_MOP_TRACKER_HISTORY'::text),
        true
      ),
      '{unit_weight_evidence_count}',
      to_jsonb(seed.evidence_count),
      true
    ),
    updated_at = now()
from verified_weight_seed seed
join public.product_types pt
  on pt.product_code='MOP'
 and pt.active=true
 and pt.deleted_at is null
where pv.product_type_id=pt.product_type_id
  and pv.variant_code=seed.variant_code
  and pv.deleted_at is null
  and nullif(coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams',''),'') is null;

update public.product_variants pv
set metadata = jsonb_set(
      jsonb_set(
        coalesce(pv.metadata,'{}'::jsonb),
        '{unit_weight_review_required}',
        'true'::jsonb,
        true
      ),
      '{legacy_weight_observations}',
      '{"130":55,"120":8}'::jsonb,
      true
    ),
    updated_at = now()
from public.product_types pt
where pv.product_type_id=pt.product_type_id
  and pt.product_code='MOP'
  and pt.deleted_at is null
  and pv.variant_code='STANDARD_POCKET_MOPS'
  and pv.deleted_at is null
  and nullif(coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams',''),'') is null;

-- ---------------------------------------------------------------------
-- 1. Rich MOP catalogue read model.
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
    'can_manage', public.has_any_role(array['ADMIN','MANAGER']),
    'can_create', public.has_any_role(array['ADMIN','MANAGER']),
    'types', v_types
  );
end;
$$;

revoke all on function public.get_sorting_mop_type_catalog()
  from public, anon, authenticated;
grant execute on function public.get_sorting_mop_type_catalog()
  to authenticated;

-- ---------------------------------------------------------------------
-- 2. Create a new MOP catalogue type.
--    variant_code is normalized once and then becomes permanent.
-- ---------------------------------------------------------------------

create or replace function public.create_sorting_mop_type_master(
  p_variant_code text,
  p_display_name text,
  p_category text default null,
  p_unit_weight_grams numeric default null,
  p_notes text default null,
  p_image_url text default null,
  p_sort_order integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
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
  if not public.has_any_role(array['ADMIN','MANAGER']) then
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
$$;

revoke all on function public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)
  from public, anon, authenticated;
grant execute on function public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. Rich update API. The existing update RPC from Migration 031 remains
--    available for compatibility, but the new UI uses this V2 contract.
--    variant_code and active status are intentionally not editable here.
-- ---------------------------------------------------------------------

create or replace function public.update_sorting_mop_type_master_v2(
  p_product_variant_id uuid,
  p_display_name text,
  p_category text default null,
  p_unit_weight_grams numeric default null,
  p_notes text default null,
  p_image_url text default null,
  p_remove_image boolean default false,
  p_sort_order integer default null
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
  v_category text;
  v_notes text;
  v_image_url text;
  v_sort_order integer;
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
$$;

revoke all on function public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)
  from public, anon, authenticated;
grant execute on function public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)
  to authenticated;

comment on function public.get_sorting_mop_type_catalog() is
  'Sorting MOP Types Management read model. Returns saved MOP variants, photo/weight/category metadata and usage counts.';
comment on function public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer) is
  'ADMIN/MANAGER controlled creation of a MOP product variant. variant_code becomes permanent after creation.';
comment on function public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer) is
  'ADMIN/MANAGER controlled MOP master maintenance. Does not change variant_code or active status.';

commit;
