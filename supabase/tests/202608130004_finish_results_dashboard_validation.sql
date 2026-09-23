-- ElisCaretex V2 — Validation 050 — Finish Results dashboard
-- Structural validation only. Safe in SQL Editor without app auth.

do $$
declare
  v_def text;
  v_acl_ok boolean;
begin
  if to_regprocedure('public.get_finish_results_dashboard(date)') is null then
    raise exception 'VALIDATION 050 FAIL: get_finish_results_dashboard(date) is missing.';
  end if;

  select pg_get_functiondef('public.get_finish_results_dashboard(date)'::regprocedure)
  into v_def;

  if position('FINISH_RESULTS_V1' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: FINISH_RESULTS_V1 contract marker is missing.';
  end if;
  if position('FINISH_TABLE_KG_PER_STAFF_HOUR' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: governed Finish target is not used.';
  end if;
  if position('get_finish_staff_context_v2' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: Results does not reuse the governed Finish staff context.';
  end if;
  if position('e.status=''ACTIVE''' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: Results is not restricted to active Finish revisions.';
  end if;
  if position('FINISH_TABLE_1' in v_def)=0 or position('FINISH_TABLE_2' in v_def)=0 or position('FINISH_TABLE_3' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: one or more Finish Tables are missing from the matrix.';
  end if;
  if position('MORNING' in v_def)=0 or position('EVENING' in v_def)=0 then
    raise exception 'VALIDATION 050 FAIL: Morning/Evening split is missing.';
  end if;

  select has_function_privilege('authenticated','public.get_finish_results_dashboard(date)','EXECUTE')
  into v_acl_ok;
  if not coalesce(v_acl_ok,false) then
    raise exception 'VALIDATION 050 FAIL: authenticated role cannot execute Results RPC.';
  end if;

  raise notice 'VALIDATION 050 PASS';
end;
$$;

select jsonb_build_object(
  'validation','050',
  'status','PASS',
  'function_exists',to_regprocedure('public.get_finish_results_dashboard(date)') is not null,
  'authenticated_execute',has_function_privilege('authenticated','public.get_finish_results_dashboard(date)','EXECUTE'),
  'finish_target',(select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active=true limit 1),
  'active_finish_entries',(select count(*) from public.finish_production_entries where status='ACTIVE')
) as validation_result;
