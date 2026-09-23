-- DEVELOPMENT-ONLY cleanup for SIM_FINISH_SNAPSHOT_115_V1
begin;
delete from public.production_flow_events where source_application='SIM_FINISH_SNAPSHOT_115_V1';
delete from public.finish_production_trolleys where finish_production_entry_id in (select finish_production_entry_id from public.finish_production_entries where source_application='SIM_FINISH_SNAPSHOT_115_V1');
delete from public.finish_production_lines where finish_production_entry_id in (select finish_production_entry_id from public.finish_production_entries where source_application='SIM_FINISH_SNAPSHOT_115_V1');
delete from public.finish_production_entries where source_application='SIM_FINISH_SNAPSHOT_115_V1';
commit;
select jsonb_build_object('simulation','SIM_FINISH_SNAPSHOT_115_V1','status','REMOVED') as cleanup_result;
