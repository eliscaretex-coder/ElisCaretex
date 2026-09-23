-- ElisCaretex V2
-- Validation 031: MOP type photo management + Washing Reception Exception
-- Status: PREPARED — owner-run only. V2 fixes brittle pg_get_functiondef whitespace matching.
-- Expected result: one row with status = PASS.
-- This validation is structural/security focused and does not create business rows.

DO $$
DECLARE
  v_bucket record;
  v_policy_count integer;
  v_def text;
  v_rls boolean;
BEGIN
  -- Storage bucket is a documented owner precondition created through Supabase Storage UI/API.
  select id,name,public,file_size_limit,allowed_mime_types
  into v_bucket
  from storage.buckets
  where id='mop-type-photos';

  if not found then
    raise exception 'Validation 031 failed: Storage bucket mop-type-photos is missing. Create it as public, 2 MB max, JPG/PNG/WebP before rerunning validation.';
  end if;

  if v_bucket.public is not true
     or coalesce(v_bucket.file_size_limit,0) <> 2097152
     or not ('image/jpeg'=any(v_bucket.allowed_mime_types))
     or not ('image/png'=any(v_bucket.allowed_mime_types))
     or not ('image/webp'=any(v_bucket.allowed_mime_types)) then
    raise exception 'Validation 031 failed: mop-type-photos bucket configuration must be public, 2 MB max, image/jpeg + image/png + image/webp.';
  end if;

  select count(*)::integer into v_policy_count
  from pg_policies
  where schemaname='storage' and tablename='objects'
    and policyname in (
      'mop_type_photos_manager_select',
      'mop_type_photos_manager_insert',
      'mop_type_photos_manager_update',
      'mop_type_photos_manager_delete'
    );
  if v_policy_count<>4 then
    raise exception 'Validation 031 failed: expected four manager-only MOP photo Storage policies; found %.',v_policy_count;
  end if;

  if not has_function_privilege('authenticated','public.get_sorting_mop_type_catalog()','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_mop_type_catalog()','EXECUTE') then
    raise exception 'Validation 031 failed: MOP type catalog RPC grants are incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.update_sorting_mop_type_master(uuid,text,numeric,text,text,boolean)','EXECUTE')
     or has_function_privilege('anon','public.update_sorting_mop_type_master(uuid,text,numeric,text,text,boolean)','EXECUTE') then
    raise exception 'Validation 031 failed: MOP type update RPC grants are incorrect.';
  end if;

  select pg_get_functiondef('public.update_sorting_mop_type_master(uuid,text,numeric,text,text,boolean)'::regprocedure)
  into v_def;
  if position($q$has_any_role(array['ADMIN','MANAGER'])$q$ in replace(v_def,' ',''))=0
     or position('MOP_TYPE_MASTER_UPDATED' in v_def)=0
     or position('unit_weight_grams' in v_def)=0
     or position('image_url' in v_def)=0 then
    raise exception 'Validation 031 failed: MOP type update RPC is missing manager guard/audit/metadata contract.';
  end if;

  if to_regclass('public.sorting_wash_reception_exceptions') is null then
    raise exception 'Validation 031 failed: sorting_wash_reception_exceptions table is missing.';
  end if;

  select c.relrowsecurity into v_rls
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='sorting_wash_reception_exceptions';
  if coalesce(v_rls,false) is not true then
    raise exception 'Validation 031 failed: Reception exception table RLS is not enabled.';
  end if;

  if has_table_privilege('authenticated','public.sorting_wash_reception_exceptions','SELECT')
     or has_table_privilege('anon','public.sorting_wash_reception_exceptions','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_reception_exceptions','INSERT')
     or has_table_privilege('anon','public.sorting_wash_reception_exceptions','INSERT') then
    raise exception 'Validation 031 failed: direct Reception exception table access must remain revoked.';
  end if;

  if not has_function_privilege('authenticated','public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text)','EXECUTE')
     or has_function_privilege('anon','public.save_sorting_wash_run_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text)','EXECUTE') then
    raise exception 'Validation 031 failed: live Washing V4 grants are incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)','EXECUTE')
     or has_function_privilege('anon','public.save_sorting_missed_wash_v4(text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)','EXECUTE') then
    raise exception 'Validation 031 failed: missed Washing V4 grants are incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)','EXECUTE')
     or has_function_privilege('anon','public.correct_sorting_wash_run_v4(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,jsonb,text,text)','EXECUTE') then
    raise exception 'Validation 031 failed: correction Washing V4 grants are incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.get_sorting_washing_context_v4(text)','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_washing_context_v4(text)','EXECUTE') then
    raise exception 'Validation 031 failed: Washing context V4 grants are incorrect.';
  end if;

  -- Private helpers must stay private. This explicitly avoids the Validation 030 V3 mistake
  -- of trying to execute a deliberately private helper as authenticated.
  if has_function_privilege('authenticated','public.sorting_wash_selection_has_reception_evidence(date,text,uuid,uuid,date)','EXECUTE')
     or has_function_privilege('anon','public.sorting_wash_selection_has_reception_evidence(date,text,uuid,uuid,date)','EXECUTE')
     or has_function_privilege('authenticated','public.sorting_assert_wash_reception_gate_v2(date,text,jsonb,jsonb)','EXECUTE')
     or has_function_privilege('anon','public.sorting_assert_wash_reception_gate_v2(date,text,jsonb,jsonb)','EXECUTE')
     or has_function_privilege('authenticated','public.sorting_record_wash_reception_exceptions(uuid,jsonb)','EXECUTE')
     or has_function_privilege('anon','public.sorting_record_wash_reception_exceptions(uuid,jsonb)','EXECUTE') then
    raise exception 'Validation 031 failed: private Washing exception helpers are executable by browser roles.';
  end if;

  select pg_get_functiondef('public.sorting_assert_wash_reception_gate_v2(date,text,jsonb,jsonb)'::regprocedure)
  into v_def;
  if position('sorting_assert_wash_scan_gate' in v_def)=0
     or position('Reception exception' in v_def)=0
     or position($q$v_reason:=trim(coalesce(v_exception.value->>'reason',''))$q$ in replace(v_def,' ',''))=0
     or position('length(v_reason)<5' in replace(v_def,' ',''))=0 then
    raise exception 'Validation 031 failed: Washing exception gate does not preserve the normal gate + mandatory reason contract.';
  end if;

  select pg_get_functiondef('public.sorting_record_wash_reception_exceptions(uuid,jsonb)'::regprocedure)
  into v_def;
  if position('sorting_wash_selection_has_reception_evidence' in v_def)=0
     or position('SORTING_WASH_RECEPTION_EXCEPTION_RECORDED' in v_def)=0
     or position('wash_run_id' in v_def)=0 then
    raise exception 'Validation 031 failed: exception writer is missing normal-evidence check, Wash linkage or audit action.';
  end if;

  select pg_get_functiondef('public.get_sorting_washing_context_v4(text)'::regprocedure)
  into v_def;
  if position('reception_exception_count' in v_def)=0
     or position('reception_exceptions' in v_def)=0 then
    raise exception 'Validation 031 failed: Washing context V4 does not expose exception history.';
  end if;
END;
$$;

select jsonb_build_object(
  'test','202608110011_sorting_mop_ui_master_and_wash_reception_exception_validation',
  'status','PASS',
  'mop_type_photo_bucket','mop-type-photos',
  'mop_type_master_manager_guard',true,
  'washing_reception_exception_reason_required',true,
  'washing_exception_linked_to_wash_id',true,
  'normal_reception_gate_preserved',true,
  'private_helpers_not_browser_executable',true,
  'direct_exception_table_access_revoked',true,
  'writes_created',false,
  'owner_run',true
) as validation_result;
