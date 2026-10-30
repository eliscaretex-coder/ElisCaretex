-- =====================================================================
-- ElisCaretex V2
-- Customer Schedule (read-only view): units on every trolley and label data
--
-- Owner report 2026-10-30: on the Finish Table 1 computer (FINISH_OPERATOR
-- terminal) the customer schedule did not show the unit names on the trolleys
-- nor the print-label button. Accounts that cannot manage Customer Schedules
-- read get_customer_weekly_schedule, which did not return the trolley plates.
--
-- get_customer_weekly_schedule now also returns, with the same permission
-- checks and the same visible services as before:
-- * per trolley row (trolley_breakdown): plates with plate_number,
--   subunit_names (unit names, in order) and instructions;
-- * per day: route_code and delivery_weekday;
-- * per schedule version: delivery_weekdays (every active day of the version).
-- These are the same values Finish / MOP Production already show to the same
-- roles through get_production_flow_trolley_plates.
--
-- The function is patched in place from its live definition: every
-- replacement must match exactly once or the migration stops.
-- =====================================================================

do $patch$
declare
  v_fn regprocedure := 'public.get_customer_weekly_schedule(uuid,date)'::regprocedure;
  v_patch record;
  v_definition text;
  v_count integer;
begin
  v_definition := pg_get_functiondef(v_fn);

  for v_patch in
    select *
    from (values
      -- Trolley plates with their unit names.
      (1, $old$'notes', req.notes$old$,
       $new$'notes', req.notes,
            'plates', (
              select coalesce(jsonb_agg(
                       jsonb_build_object(
                         'plate_number', pl.plate_number,
                         'subunit_names', to_jsonb(coalesce((
                           select array_agg(su.subunit_name order by s.ordinal)
                           from unnest(pl.subunit_ids) with ordinality as s(subunit_id, ordinal)
                           join public.customer_subunits su on su.subunit_id = s.subunit_id
                         ), array[]::text[])),
                         'instructions', pl.instructions
                       )
                       order by pl.plate_number
                     ), '[]'::jsonb)
              from public.customer_schedule_trolley_plates pl
              where pl.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
                and pl.plate_number <= req.quantity
            )$new$),
      -- Route number and delivery weekday of each day.
      (2, $old$'visible_trolley_total', dp.visible_trolley_total,$old$,
       $new$'visible_trolley_total', dp.visible_trolley_total,
            'delivery_weekday', (
              select d2.delivery_weekday
              from public.customer_schedule_days d2
              where d2.schedule_day_id = dp.schedule_day_id
            ),
            'route_code', (
              select r2.route_code
              from public.customer_schedule_days d2
              join public.distribution_routes r2
                on r2.route_id = d2.default_route_id
               and r2.active = true
               and r2.deleted_at is null
              where d2.schedule_day_id = dp.schedule_day_id
            ),$new$),
      -- Delivery weekdays of the whole version (every service).
      (3, $old$'published_at', v_version.published_at$old$,
       $new$'published_at', v_version.published_at,
      'delivery_weekdays', (
        select coalesce(jsonb_agg(w.delivery_weekday order by w.delivery_weekday), '[]'::jsonb)
        from (
          select distinct d2.delivery_weekday
          from public.customer_schedule_days d2
          where d2.schedule_version_id = v_version.schedule_version_id
            and d2.active = true
            and d2.delivery_weekday between 1 and 7
        ) w
      )$new$)
    ) as patches(step, old_text, new_text)
    order by step
  loop
    v_count := (length(v_definition) - length(replace(v_definition, v_patch.old_text, '')))
      / length(v_patch.old_text);

    if v_count <> 1 then
      raise exception 'Weekly schedule patch %: % occurrence(s) of "%", expected 1.',
        v_patch.step, v_count, v_patch.old_text;
    end if;

    v_definition := replace(v_definition, v_patch.old_text, v_patch.new_text);
  end loop;

  execute v_definition;
end;
$patch$;

revoke all on function public.get_customer_weekly_schedule(uuid, date) from public, anon;
grant execute on function public.get_customer_weekly_schedule(uuid, date) to authenticated;
