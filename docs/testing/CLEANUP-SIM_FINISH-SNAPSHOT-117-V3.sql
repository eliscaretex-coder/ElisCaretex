-- DEVELOPMENT-ONLY cleanup for SIM_FINISH_SNAPSHOT_117_V3
begin;

do $$
declare
  v_marker constant text := 'SIM_FINISH_SNAPSHOT_117_V3';
  v_trolley_links integer;
  v_flow_events integer;
begin
  select count(*) into v_trolley_links
  from public.finish_production_trolleys ft
  join public.finish_production_entries e on e.finish_production_entry_id=ft.finish_production_entry_id
  where e.entry_group_id in (
    select entry_group_id from public.finish_production_entries where source_application=v_marker
  );

  if v_trolley_links>0 then
    raise exception 'Cleanup stopped: % physical trolley link(s) exist on simulation groups. Do not delete lifecycle evidence manually.',v_trolley_links;
  end if;

  select count(*) into v_flow_events
  from public.production_flow_events ev
  where ev.source_entity_table='finish_production_entries'
    and ev.source_entity_id in (
      select e.finish_production_entry_id::text
      from public.finish_production_entries e
      where e.entry_group_id in (
        select entry_group_id from public.finish_production_entries where source_application=v_marker
      )
    );

  if v_flow_events>0 then
    raise exception 'Cleanup stopped: % Production Flow event(s) exist on simulation groups. The simulation was edited through the app; do not remove trace evidence with this visual cleanup.',v_flow_events;
  end if;

  delete from public.finish_production_lines l
  using public.finish_production_entries e
  where l.finish_production_entry_id=e.finish_production_entry_id
    and e.entry_group_id in (
      select entry_group_id from public.finish_production_entries where source_application=v_marker
    );

  delete from public.finish_production_entries e
  where e.entry_group_id in (
    select x.entry_group_id
    from public.finish_production_entries x
    where x.source_application=v_marker
  );
end;
$$;

commit;

select jsonb_build_object(
  'simulation','SIM_FINISH_SNAPSHOT_117_V3',
  'remaining_entries',(select count(*) from public.finish_production_entries where source_application='SIM_FINISH_SNAPSHOT_117_V3')
) as cleanup_result;
