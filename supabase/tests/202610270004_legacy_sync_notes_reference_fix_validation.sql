-- ElisCaretex V2 - Validation - 202610270004_legacy_sync_notes_reference_fix
-- Runs entirely inside one transaction and ends with ROLLBACK: nothing is kept.
-- Plain SQL assertions (pgTAP is not installed on the remote project).
-- Every failed assertion raises an exception and aborts the run.

begin;

create function pg_temp.check(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'ok - %', p_label;
end;
$$;

select pg_temp.check(integration.legacy_sync_notes_reference(
  'Imported from local Finish workbook; source group FINISH:FE-20261024-085110-3DBCFBA1.', 'FE-20261024-085110-3DBCFBA1'),
  'workbook notes ending with a full stop match');
select pg_temp.check(integration.legacy_sync_notes_reference(
  'Historical CentralDB import; source group FINISH:FE-1; delivery derived from source CustomerSchedule.', 'FE-1'),
  'CentralDB notes followed by ";" match');
select pg_temp.check(integration.legacy_sync_notes_reference('Legacy Finish sync; source group FINISH:FE-1', 'FE-1'),
  'ID at the end of the notes matches');
select pg_temp.check(not integration.legacy_sync_notes_reference('source group FINISH:FE-12.', 'FE-1'),
  'a longer ID does not match a shorter one');
select pg_temp.check(not integration.legacy_sync_notes_reference('source group FINISH:FE-1', 'FE-12'),
  'a shorter ID does not match a longer one');
select pg_temp.check(integration.legacy_sync_notes_reference(null, 'FE-1') is false,
  'null notes do not match');
select pg_temp.check(not has_function_privilege('authenticated','integration.legacy_sync_notes_reference(text,text)','execute'),
  'authenticated cannot call the helper');

-- Every earlier-import entry is found by its own EntryID.
select pg_temp.check(not exists (
    select 1 from public.finish_production_entries e
    where e.source_application in ('APPS_SCRIPT_CENTRALDB_20261023_001','LOCAL_FINISH_WORKBOOK_20261024')
      and not integration.legacy_sync_notes_reference(e.notes, substring(e.notes from 'source group FINISH:([A-Za-z0-9_-]+)'))),
  'every earlier-import entry matches its own EntryID');

rollback;
