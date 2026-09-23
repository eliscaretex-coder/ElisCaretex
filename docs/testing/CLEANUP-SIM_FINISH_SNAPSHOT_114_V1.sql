-- DEVELOPMENT-ONLY cleanup for SIM_FINISH_SNAPSHOT_114_V1.
begin;

delete from public.production_flow_events
where source_application='SIM_FINISH_SNAPSHOT_114_V1';

delete from public.finish_production_trolleys ft
using public.finish_production_entries e
where ft.finish_production_entry_id=e.finish_production_entry_id
  and e.source_application='SIM_FINISH_SNAPSHOT_114_V1';

delete from public.finish_production_lines l
using public.finish_production_entries e
where l.finish_production_entry_id=e.finish_production_entry_id
  and e.source_application='SIM_FINISH_SNAPSHOT_114_V1';

delete from public.finish_production_entries
where source_application='SIM_FINISH_SNAPSHOT_114_V1';

delete from public.work_sessions
where notes='SIM_FINISH_SNAPSHOT_114_V1'
  and source='FINISH_V2'
  and production_roster_entry_id is null;

commit;

select jsonb_build_object(
  'cleanup','SIM_FINISH_SNAPSHOT_114_V1',
  'status','DONE',
  'remaining_entries',(select count(*) from public.finish_production_entries where source_application='SIM_FINISH_SNAPSHOT_114_V1'),
  'remaining_sessions',(select count(*) from public.work_sessions where notes='SIM_FINISH_SNAPSHOT_114_V1')
) as cleanup_result;
