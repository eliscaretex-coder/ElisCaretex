-- Read-only reconciliation of the 2026-09-26 Apps Script history import:
-- staging rows marked IMPORTED versus the operational rows they point to.
-- It proves staging -> target. Source file -> staging still needs the owner's
-- original exports (see docs/database/apps-script-history-reconciliation.md).
begin;
select plan(8);

select results_eq(
  $$select count(*)::integer from staging.apps_script_finish_lines
    where import_status = 'IMPORTED' and target_record_id is null$$,
  array[0], 'every imported Finish staging row has a target');

select results_eq(
  $$select count(*)::integer
    from public.finish_production_entries e
    join public.finish_production_lines l using (finish_production_entry_id)
    where e.status = 'ACTIVE' and e.source_application = 'APPS_SCRIPT_IMPORT'
      and not exists (select 1 from staging.apps_script_finish_lines s
                      where s.target_record_id = l.finish_production_line_id)$$,
  array[0], 'every active imported Finish line traces back to staging');

select results_eq(
  $$select count(*)::integer
    from staging.apps_script_finish_lines s
    join public.finish_production_lines l on l.finish_production_line_id = s.target_record_id
    where s.v_quantity is distinct from l.quantity or s.unit_code is distinct from l.unit_code$$,
  array[0], 'Finish line quantity and unit equal the staging value');

select results_eq(
  $$select coalesce(sum(l.quantity), 0)::numeric(14,2)
    from public.finish_production_entries e
    join public.finish_production_lines l using (finish_production_entry_id)
    where e.status = 'ACTIVE' and e.source_application = 'APPS_SCRIPT_IMPORT' and l.unit_code = 'KG'$$,
  $$select coalesce(sum(s.v_quantity), 0)::numeric(14,2)
    from staging.apps_script_finish_lines s
    join public.finish_production_lines l on l.finish_production_line_id = s.target_record_id
    join public.finish_production_entries e using (finish_production_entry_id)
    where e.status = 'ACTIVE' and s.unit_code = 'KG'$$,
  'active imported Finish KG equals the staging KG behind it');

select results_eq(
  $$select count(*)::integer from staging.apps_script_finish_lines
    where import_status = 'IMPORTED' and production_kind = 'HOUSEHOLD'$$,
  array[0], 'HOUSEHOLD rows stay out of official Finish KG (owner decision 2026-09-26)');

select results_eq(
  $$select count(*)::integer
    from staging.apps_script_finish_lines s
    where s.production_kind = 'REWASH' and s.import_status = 'IMPORTED'
      and not exists (select 1 from public.finish_rewash_lines r
                      where r.finish_rewash_line_id = s.target_record_id)
      and not exists (select 1 from public.finish_rewash_entries r
                      where r.finish_rewash_entry_id = s.target_record_id)$$,
  array[0], 'every imported ReWash staging row reaches the ReWash ledger');

select results_eq(
  $$select count(*)::integer from staging.apps_script_mop_lines s
    where s.import_status = 'IMPORTED'
      and not exists (select 1 from public.sorting_mop_production_lines l
                      where l.mop_production_line_id = s.target_record_id)$$,
  array[0], 'every imported MOP staging row has a MOP line');

select results_eq(
  $$select coalesce(sum(s.v_weight_kg), 0)::numeric(14,2)
    from staging.apps_script_mop_lines s where s.import_status = 'IMPORTED'$$,
  $$select coalesce(sum(b.total_weight_kg), 0)::numeric(14,2)
    from public.sorting_mop_production_batches b
    where b.status = 'RECORDED'
      and exists (select 1 from public.sorting_mop_production_lines l
                  join staging.apps_script_mop_lines s on s.target_record_id = l.mop_production_line_id
                  where l.mop_production_batch_id = b.mop_production_batch_id)$$,
  'imported MOP KG equals the recorded batches behind it');

select * from finish();
rollback;
