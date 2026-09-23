-- Simulation records remain protected for later cleanup, but must never block
-- a real Finish workstation as if they were operational wash evidence.

do $$
declare
  v_definition text;
  v_old_guard constant text:='and coalesce(pfi.washed_trace_count,0)>0';
  v_new_guard constant text:=$guard$
and coalesce(pfi.washed_trace_count,0)>0
      and exists (
        select 1
        from public.production_flow_events wash_event
        where wash_event.production_flow_item_id=pfi.production_flow_item_id
          and wash_event.event_type='WASH_RECORDED'
          and left(coalesce(wash_event.source_application,''),4)<>'SIM_'
      )$guard$;
begin
  select pg_get_functiondef('public.get_finish_delivery_reconciliation_context(timestamptz)'::regprocedure)
  into v_definition;
  if position(v_old_guard in v_definition)=0 then
    raise exception 'Expected Finish wash-evidence guard was not found.';
  end if;
  execute replace(v_definition,v_old_guard,v_new_guard);
end;
$$;

revoke all on function public.get_finish_delivery_reconciliation_context(timestamptz) from public,anon;
grant execute on function public.get_finish_delivery_reconciliation_context(timestamptz) to authenticated;

comment on function public.get_finish_delivery_reconciliation_context(timestamptz) is
  'Returns overdue real Clothes washes only. SIM_ source records are excluded until their protected cleanup can be completed.';
