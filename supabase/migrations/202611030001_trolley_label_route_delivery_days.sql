-- =====================================================================
-- ElisCaretex V2
-- Trolley label: delivery days of the label's route only
--
-- Owner request 2026-11-02: some customers are delivered by more than one
-- route in the week (for example Mon->Tue on route 612 and Fri->Sat on route
-- 616). The label listed every delivery day of the schedule next to one
-- route, so in a rush the staff could load the trolley on the wrong route.
--
-- get_production_flow_trolley_plates now lists only the delivery days of the
-- schedule days that use the same default route as the production day of the
-- label. When that day has no route, every delivery day is listed as before.
-- Permissions, inputs and the rest of the result are unchanged.
--
-- The function is patched in place from its live definition: the replacement
-- must match exactly once or the migration stops.
-- =====================================================================

do $patch$
declare
  v_fn regprocedure := 'public.get_production_flow_trolley_plates(uuid)'::regprocedure;
  v_definition text;
  v_old text := 'and d.delivery_weekday between 1 and 7';
  v_new text := $new$and d.delivery_weekday between 1 and 7
      -- Only the days delivered by the route of this label's production day.
      and d.default_route_id is not distinct from coalesce(
        (select d_route.default_route_id
         from public.customer_schedule_days d_route
         where d_route.schedule_version_id = v_version_id
           and d_route.production_weekday = v_weekday
           and d_route.active = true
         limit 1),
        v_item.route_id_snapshot,
        d.default_route_id
      )$new$;
  v_count integer;
begin
  v_definition := pg_get_functiondef(v_fn);
  v_count := (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old);

  if v_count <> 1 then
    raise exception 'Trolley label route patch: % occurrence(s) of "%", expected 1.', v_count, v_old;
  end if;

  execute replace(v_definition, v_old, v_new);
end;
$patch$;

revoke all on function public.get_production_flow_trolley_plates(uuid) from public, anon;
grant execute on function public.get_production_flow_trolley_plates(uuid) to authenticated;

comment on function public.get_production_flow_trolley_plates(uuid) is
  'Finish / MOP Production: one row per planned trolley of a production item with its units and instruction. Delivery days are those of the label''s route.';
