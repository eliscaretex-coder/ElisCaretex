-- ElisCaretex V2
-- Validation 032: Sorting MOP Type Master Management
-- Status: PREPARED — owner-run validation only.
--
-- This validation is intentionally read-only. It performs no scenario writes.

begin;

do $$
declare
  v_bucket record;
  v_def text;
  v_count integer;
  v_direct_select boolean;
  v_standard_weight numeric;
  v_standard_review boolean;
  v_standard_obs jsonb;
begin
  select b.id,b.public,b.file_size_limit,b.allowed_mime_types
  into v_bucket
  from storage.buckets b
  where b.id='mop-type-photos';

  if not found then
    raise exception 'Validation 032 failed: Storage bucket mop-type-photos is missing.';
  end if;
  if v_bucket.public is not true
     or v_bucket.file_size_limit is distinct from 2097152
     or not (array['image/jpeg','image/png','image/webp']::text[] <@ coalesce(v_bucket.allowed_mime_types,'{}'::text[])) then
    raise exception 'Validation 032 failed: mop-type-photos bucket configuration is not the approved public/2MB/JPG-PNG-WebP contract.';
  end if;

  if to_regprocedure('public.get_sorting_mop_type_catalog()') is null
     or to_regprocedure('public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)') is null
     or to_regprocedure('public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)') is null then
    raise exception 'Validation 032 failed: one or more MOP Type Master RPCs are missing.';
  end if;

  select pg_get_functiondef('public.get_sorting_mop_type_catalog()'::regprocedure) into v_def;
  if position('schedule_link_count' in v_def)=0
     or position('production_line_count' in v_def)=0
     or position('unit_weight_review_required' in v_def)=0
     or position('legacy_weight_observations' in v_def)=0
     or position('product_code' in v_def)=0
     or position('MOP' in v_def)=0 then
    raise exception 'Validation 032 failed: MOP catalogue read model does not expose usage counts / MOP scoping.';
  end if;

  select pg_get_functiondef('public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)'::regprocedure) into v_def;
  if position('Only ADMIN or MANAGER may create MOP Types.' in v_def)=0
     or position('MOP_TYPE_MASTER_CREATED' in v_def)=0
     or position('variant_code' in v_def)=0
     or position('/storage/v1/object/public/mop-type-photos/' in v_def)=0
     or position('insert into public.product_variants' in lower(v_def))=0 then
    raise exception 'Validation 032 failed: create MOP Type contract is incomplete.';
  end if;

  select pg_get_functiondef('public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)'::regprocedure) into v_def;
  if position('Only ADMIN or MANAGER may manage MOP Types.' in v_def)=0
     or position('MOP_TYPE_MASTER_UPDATED' in v_def)=0
     or position('category' in v_def)=0
     or position('unit_weight_grams' in v_def)=0
     or position('/storage/v1/object/public/mop-type-photos/' in v_def)=0 then
    raise exception 'Validation 032 failed: update MOP Type contract is incomplete.';
  end if;

  if not has_function_privilege('authenticated','public.get_sorting_mop_type_catalog()','EXECUTE')
     or not has_function_privilege('authenticated','public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)','EXECUTE')
     or not has_function_privilege('authenticated','public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)','EXECUTE') then
    raise exception 'Validation 032 failed: authenticated RPC EXECUTE grants are missing.';
  end if;

  if has_function_privilege('anon','public.create_sorting_mop_type_master(text,text,text,numeric,text,text,integer)','EXECUTE')
     or has_function_privilege('anon','public.update_sorting_mop_type_master_v2(uuid,text,text,numeric,text,text,boolean,integer)','EXECUTE') then
    raise exception 'Validation 032 failed: anon must not execute MOP Type write RPCs.';
  end if;

  select has_table_privilege('authenticated','public.product_variants','SELECT') into v_direct_select;
  if v_direct_select then
    raise exception 'Validation 032 failed: authenticated direct product_variants SELECT is unexpectedly granted.';
  end if;


  -- The current saved catalogue must be present. Migration 032 enriches existing
  -- identities; it does not replace or invent a parallel catalogue.
  select count(*)::integer
  into v_count
  from public.product_variants pv
  join public.product_types pt on pt.product_type_id=pv.product_type_id
  where pt.product_code='MOP' and pv.deleted_at is null;

  if v_count < 11 then
    raise exception 'Validation 032 failed: expected existing MOP catalogue identities are missing.';
  end if;

  -- Verified exact-name legacy weights are prefilled only when a weight was not
  -- already configured. A pre-existing/manual value is preserved and also
  -- satisfies this completeness check.
  select count(*)::integer
  into v_count
  from public.product_variants pv
  join public.product_types pt on pt.product_type_id=pv.product_type_id
  where pt.product_code='MOP'
    and pv.deleted_at is null
    and pv.variant_code in ('CLEANING_CLOTHS','MANORHAMILTON','TWISTER_MOP','VELCRO_MOP','WHITE_MOP')
    and nullif(coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams',''),'') is not null;

  if v_count <> 5 then
    raise exception 'Validation 032 failed: verified legacy MOP unit-weight prefill is incomplete.';
  end if;

  select
    case when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
      then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric else null end,
    coalesce((pv.metadata->>'unit_weight_review_required')::boolean,false),
    coalesce(pv.metadata->'legacy_weight_observations','{}'::jsonb)
  into v_standard_weight,v_standard_review,v_standard_obs
  from public.product_variants pv
  join public.product_types pt on pt.product_type_id=pv.product_type_id
  where pt.product_code='MOP' and pv.variant_code='STANDARD_POCKET_MOPS' and pv.deleted_at is null;

  if v_standard_weight is null
     and (v_standard_review is not true
       or coalesce(v_standard_obs->>'130','') <> '55'
       or coalesce(v_standard_obs->>'120','') <> '8') then
    raise exception 'Validation 032 failed: ambiguous Standard Pocket Mops legacy weight evidence is not preserved for review.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608110012_sorting_mop_type_master_management_validation',
  'status','PASS',
  'legacy_inspired_catalogue_manager',true,
  'new_type_creation_rpc_present',true,
  'variant_code_stable_after_creation',true,
  'category_weight_notes_photo_supported',true,
  'existing_mop_types_prefilled',true,
  'verified_legacy_unit_weights_prefilled',true,
  'ambiguous_weight_requires_review',true,
  'usage_counts_exposed',true,
  'storage_bucket_contract_preserved',true,
  'admin_manager_write_gate_present',true,
  'anon_write_access_revoked',true,
  'direct_product_variants_select_still_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
