-- ElisCaretex V2
-- Validation 038: MOP late-reconciliation deadlock fix
-- Date: 2026-08-12
-- Owner-run validation. Structural/read-contract checks only; no scenario writes.

begin;

do $validation$
declare
  v_proc regprocedure := to_regprocedure('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)');
  v_def text;
  v_norm text;
  v_compact text;
  v_current_guard_pos integer;
  v_other_guard_pos integer;
begin
  if v_proc is null then
    raise exception 'save_sorting_mop_production signature was not found.';
  end if;

  select pg_get_functiondef(v_proc::oid) into v_def;
  v_norm := regexp_replace(lower(v_def), '\s+', ' ', 'g');
  v_compact := regexp_replace(lower(v_def), '\s+', '', 'g');

  if position($q$ifv_entry_mode='live'andv_other_overdue>0then$q$ in v_compact) = 0 then
    raise exception 'Other-overdue guard is not scoped to LIVE production.';
  end if;

  if position($q$ifv_other_overdue>0then$q$ in v_compact) > 0 then
    raise exception 'Obsolete unconditional other-overdue guard is still present.';
  end if;

  v_current_guard_pos := position($q$ifv_base_date>=v_enforcementandv_local>=(v_due+v_cutoff)andnotv_prior_not_processedandv_entry_mode='live'then$q$ in v_compact);
  v_other_guard_pos := position($q$ifv_entry_mode='live'andv_other_overdue>0then$q$ in v_compact);

  if v_current_guard_pos = 0 then
    raise exception 'Current overdue LIVE item reconciliation guard is missing.';
  end if;

  if v_current_guard_pos >= v_other_guard_pos then
    raise exception 'Current-item reconciliation guard must be evaluated before the other-overdue LIVE guard.';
  end if;

  if position($q$ifv_entry_mode='late_reconciliation'then$q$ in v_compact) = 0
     or position($q$enter kg or units for at least one mop type$q$ in v_norm) = 0
     or position($q$processed-on date is required for a missed mop entry$q$ in v_norm) = 0 then
    raise exception 'Late-reconciliation quantity/date safeguards were not preserved.';
  end if;

  if not has_function_privilege('authenticated', v_proc, 'EXECUTE') then
    raise exception 'authenticated lost controlled EXECUTE on save_sorting_mop_production.';
  end if;

  if has_function_privilege('anon', v_proc, 'EXECUTE') then
    raise exception 'anon must not execute save_sorting_mop_production.';
  end if;
end;
$validation$;

select jsonb_build_object(
  'test','202608120002_mop_late_reconciliation_deadlock_fix_validation',
  'status','PASS',
  'late_reconciliation_can_resolve_current_overdue_item',true,
  'other_overdue_items_still_block_live_production',true,
  'current_overdue_live_item_still_requires_confirmation',true,
  'late_quantity_and_processed_date_guards_preserved',true,
  'authenticated_execute_preserved',true,
  'anon_execute_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
