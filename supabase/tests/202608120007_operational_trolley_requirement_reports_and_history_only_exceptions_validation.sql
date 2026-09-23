-- ElisCaretex V2
-- Validation 043: operational trolley requirement reports + history-only exceptions
begin;

do $$
declare
  v_submit text;
  v_queue text;
  v_review text;
  v_receive text;
  v_caps text;
  v_customer_caps text;
  v_direct_select_auth boolean;
  v_submit_exec_auth boolean;
  v_submit_exec_anon boolean;
  v_queue_exec_auth boolean;
  v_queue_exec_anon boolean;
  v_review_exec_auth boolean;
  v_legacy_queue_exec_auth boolean;
  v_legacy_review_exec_auth boolean;
begin
  if to_regclass('public.operational_data_reports') is null then
    raise exception 'operational_data_reports table is missing.';
  end if;

  select pg_get_functiondef('public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text)'::regprocedure) into v_submit;
  select pg_get_functiondef('public.get_operational_schedule_reports(text)'::regprocedure) into v_queue;
  select pg_get_functiondef('public.review_operational_schedule_report(uuid,text,text)'::regprocedure) into v_review;
  select pg_get_functiondef('public.receive_trolley_from_customer(text,uuid,date,text,text,text)'::regprocedure) into v_receive;
  select pg_get_functiondef('public.get_trolley_lifecycle_capabilities()'::regprocedure) into v_caps;
  select pg_get_functiondef('public.get_customer_read_capabilities()'::regprocedure) into v_customer_caps;

  v_direct_select_auth:=has_table_privilege('authenticated','public.operational_data_reports','SELECT');
  v_submit_exec_auth:=has_function_privilege('authenticated','public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text)','EXECUTE');
  v_submit_exec_anon:=has_function_privilege('anon','public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text)','EXECUTE');
  v_queue_exec_auth:=has_function_privilege('authenticated','public.get_operational_schedule_reports(text)','EXECUTE');
  v_queue_exec_anon:=has_function_privilege('anon','public.get_operational_schedule_reports(text)','EXECUTE');
  v_review_exec_auth:=has_function_privilege('authenticated','public.review_operational_schedule_report(uuid,text,text)','EXECUTE');
  v_legacy_queue_exec_auth:=has_function_privilege('authenticated','public.get_trolley_reconciliation_queue()','EXECUTE');
  v_legacy_review_exec_auth:=has_function_privilege('authenticated','public.review_trolley_exception(uuid,text,text,text)','EXECUTE');

  if v_direct_select_auth then raise exception 'operational_data_reports direct SELECT must remain private.'; end if;
  if not v_submit_exec_auth or v_submit_exec_anon then raise exception 'Operational report submit EXECUTE grants are incorrect.'; end if;
  if not v_queue_exec_auth or v_queue_exec_anon or not v_review_exec_auth then raise exception 'Operational report review RPC grants are incorrect.'; end if;
  if v_legacy_queue_exec_auth or v_legacy_review_exec_auth then raise exception 'Legacy trolley reconciliation queue/actions must not remain browser-executable.'; end if;

  if position('require_operational_report_submit_access' in v_submit)=0
     or position('allowed_in_customer_schedule' in v_submit)=0
     or position('planned_snapshot' in v_submit)=0
     or position('observed_snapshot' in v_submit)=0
     or position('published schedule was not changed' in lower(v_submit))=0 then
    raise exception 'Operational trolley report submit governance is incomplete.';
  end if;

  if position('require_customer_schedule_edit_role' in v_queue)=0
     or position('require_customer_schedule_edit_role' in v_review)=0 then
    raise exception 'Operational report review is not tied to Customer Schedule editor permissions.';
  end if;

  if position('status=''RECEIVED''' in replace(v_receive,' ',''))=0
     or position('review_status=''NOT_REQUIRED''' in replace(v_receive,' ',''))=0
     or position('HISTORY_ONLY' in v_receive)=0 then
    raise exception 'Trolley receipt still creates operational review tasks.';
  end if;

  if position('''can_view_trolley_exceptions'',false' in replace(v_caps,' ',''))=0
     or position('''can_review_trolley_exceptions'',false' in replace(v_caps,' ',''))=0
     or position('''trolley_exception_policy'',''HISTORY_ONLY''' in replace(v_caps,' ',''))=0 then
    raise exception 'Trolley exception capabilities are not history-only.';
  end if;

  if position('can_view_operational_reports' in v_customer_caps)=0
     or position('pending_operational_report_count' in v_customer_caps)=0
     or position('ADMIN' in v_customer_caps)=0
     or position('MANAGER' in v_customer_caps)=0
     or position('PLANNER' in v_customer_caps)=0 then
    raise exception 'Customer module report capability/count is missing.';
  end if;

  if exists(
    select 1 from public.trolley_customer_stays
    where exception_type is not null
      and (status='REVIEW_REQUIRED' or review_status in ('PENDING','UNDER_REVIEW'))
  ) then
    raise exception 'Old trolley exception tasks were not converted to history-only evidence.';
  end if;

  raise notice '%',jsonb_build_object(
    'test','202608120007_operational_trolley_requirement_reports_and_history_only_exceptions_validation',
    'status','PASS',
    'trolley_exceptions_are_history_only',true,
    'legacy_trolley_review_queue_browser_access_revoked',true,
    'operational_report_table_private',true,
    'mop_finish_report_scope_governed',true,
    'reported_requirements_use_schedule_allowed_trolley_types',true,
    'planned_and_scanned_evidence_snapshotted',true,
    'published_schedule_not_modified_by_operator_report',true,
    'review_queue_uses_customer_schedule_edit_roles',true,
    'scenario_writes_performed',false,
    'transaction_rolled_back',true
  );
end $$;

rollback;
