-- DEVELOPMENT-ONLY cleanup for SIM_FINISH_SNAPSHOT_116_V2
begin;
delete from public.finish_production_trolleys
where finish_production_entry_id in (
  select finish_production_entry_id from public.finish_production_entries
  where source_application='SIM_FINISH_SNAPSHOT_116_V2'
);
delete from public.finish_production_lines
where finish_production_entry_id in (
  select finish_production_entry_id from public.finish_production_entries
  where source_application='SIM_FINISH_SNAPSHOT_116_V2'
);
delete from public.finish_production_entries
where source_application='SIM_FINISH_SNAPSHOT_116_V2';
commit;
select jsonb_build_object('simulation','SIM_FINISH_SNAPSHOT_116_V2','status','REMOVED') as cleanup_result;
