-- =====================================================================
-- ElisCaretex V2
-- Legacy sync: keep the units on the trolleys (trolley plates) of a customer schedule
--
-- Owner report 2026-11-06: the units saved on the HIGHFIELD trolleys were gone.
-- Checked on 2026-11-06:
-- * revision "added the units of this customer" (published 30/10 20:10) had 55
--   trolley plates;
-- * the legacy sync of 03/11 20:10 (Tue/Sat mop.order) created a new revision
--   with 0 plates, and the two later legacy revisions (05/11, 06/11) copied that.
-- Cause: integration.legacy_sync_schedule_publish (202610280002) was written
-- before trolley plates existed (202610290001). It copies days, products,
-- variants and trolley rows of the current revision, but not the plates. Every
-- customer with units therefore loses them the next time the legacy app changes
-- anything in its schedule. In addition, legacy_sync_schedule_write_draft
-- rebuilds the trolley rows of a day when the legacy trolley text changes, which
-- also dropped the plates of that day.
--
-- Change:
-- 1. legacy_sync_schedule_publish copies the plates of every trolley row, as
--    Customer Studio does (units deactivated in Customer Master are left out,
--    plates above the trolley quantity are left out).
-- 2. legacy_sync_schedule_write_draft keeps the plates when it rebuilds the
--    trolleys of a day: a new trolley row takes the plates of the old row with
--    the same product, trolley type and empty flag (in order), up to its quantity.
-- 3. Restore: every customer whose current revision has no plates, while an
--    earlier revision had plates and every revision since then came from the
--    legacy sync, gets a new revision "Units restored ..." with the plates of
--    that earlier revision, matched by weekday, product, trolley type and empty
--    flag. Published revisions are not overwritten. Only HIGHFIELD matched on
--    2026-11-06 (55 plates). Running the block again restores nothing.
--
-- Both functions are patched in place from their live definitions (stored with
-- CRLF line ends, so every anchor is a single line): every replacement must
-- match exactly once or the migration stops.
-- =====================================================================

do $patch$
declare
  v_patch record;
  v_definition text;
  v_count integer;
begin
  for v_patch in
    select *
    from (values
      -- 1. Publish: copy the plates of each copied trolley row.
      (1, 'integration.legacy_sync_schedule_publish(uuid,uuid,text[],jsonb,text)',
       $old$returning schedule_trolley_requirement_id into v_new_req_id;$old$,
       $new$returning schedule_trolley_requirement_id into v_new_req_id;
      -- Units on the trolley (plates), as Customer Studio copies them.
      insert into public.customer_schedule_trolley_plates(schedule_trolley_requirement_id, plate_number,
        subunit_ids, instructions, created_by)
      select v_new_req_id, old_plate.plate_number,
        array(select su.subunit_id
              from unnest(old_plate.subunit_ids) with ordinality as old_subunit(subunit_id, ordinal)
              join public.customer_subunits su on su.subunit_id = old_subunit.subunit_id and su.active
              order by old_subunit.ordinal),
        old_plate.instructions, old_plate.created_by
      from public.customer_schedule_trolley_plates old_plate
      where old_plate.schedule_trolley_requirement_id = v_old_req.schedule_trolley_requirement_id
        and old_plate.plate_number <= v_old_req.quantity;$new$),
      -- 2a. Write draft: variables for the kept plates.
      (2, 'integration.legacy_sync_schedule_write_draft(uuid,text[],jsonb)',
       $old$v_window text;$old$,
       $new$v_window text;
  v_kept_plates jsonb;
  v_plate_counts jsonb;
  v_plate_key text;
  v_plate_ordinal integer;$new$),
      -- 2b. Before the trolleys of a day are rebuilt, remember their plates.
      (3, 'integration.legacy_sync_schedule_write_draft(uuid,text[],jsonb)',
       $old$delete from public.customer_schedule_trolley_requirement_products m$old$,
       $new$select coalesce(jsonb_agg(jsonb_build_object(
               'key', t.plate_key || ':' || t.ordinal,
               'plate_number', pl.plate_number,
               'subunit_ids', to_jsonb(pl.subunit_ids),
               'instructions', pl.instructions,
               'created_by', pl.created_by)), '[]'::jsonb)
      into v_kept_plates
      from (select r.schedule_trolley_requirement_id,
                   coalesce(pt.product_code, '') || ':' || coalesce(tt.trolley_type_code, '') || ':' || r.empty_trolley::text as plate_key,
                   row_number() over (partition by coalesce(pt.product_code, ''), coalesce(tt.trolley_type_code, ''), r.empty_trolley
                                      order by r.created_at, r.quantity desc, r.schedule_trolley_requirement_id) as ordinal
            from public.customer_schedule_trolley_requirements r
            left join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
            left join public.product_types pt on pt.product_type_id = p.product_type_id
            left join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id
            where r.schedule_day_id = v_day_id) t
      join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = t.schedule_trolley_requirement_id;
      v_plate_counts := '{}'::jsonb;
      delete from public.customer_schedule_trolley_requirement_products m$new$),
      -- 2c. Each rebuilt trolley row takes back the plates of its old row.
      (4, 'integration.legacy_sync_schedule_write_draft(uuid,text[],jsonb)',
       $old$returning schedule_trolley_requirement_id into v_req_id;$old$,
       $new$returning schedule_trolley_requirement_id into v_req_id;
        v_plate_key := split_part(v_t, ':', 1) || ':' || split_part(v_t, ':', 2) || ':'
                       || (split_part(v_t, ':', 4) = 'EMPTY')::text;
        v_plate_ordinal := coalesce((v_plate_counts->>v_plate_key)::integer, 0) + 1;
        v_plate_counts := v_plate_counts || jsonb_build_object(v_plate_key, v_plate_ordinal);
        insert into public.customer_schedule_trolley_plates(schedule_trolley_requirement_id, plate_number,
          subunit_ids, instructions, created_by)
        select v_req_id, (kp->>'plate_number')::integer,
          array(select su.subunit_id
                from jsonb_array_elements_text(kp->'subunit_ids') with ordinality as old_subunit(subunit_id, ordinal)
                join public.customer_subunits su on su.subunit_id = old_subunit.subunit_id::uuid and su.active
                order by old_subunit.ordinal),
          kp->>'instructions', (kp->>'created_by')::uuid
        from jsonb_array_elements(coalesce(v_kept_plates, '[]'::jsonb)) kp
        where kp->>'key' = v_plate_key || ':' || v_plate_ordinal
          and (kp->>'plate_number')::integer <= split_part(v_t, ':', 3)::integer;$new$)
    ) as patch(step, fn, old_text, new_text)
    order by step
  loop
    v_definition := pg_get_functiondef(v_patch.fn::regprocedure);
    v_count := (length(v_definition) - length(replace(v_definition, v_patch.old_text, '')))
               / length(v_patch.old_text);
    if v_count <> 1 then
      raise exception 'Patch % of % matched % times, expected 1.', v_patch.step, v_patch.fn, v_count;
    end if;
    execute replace(v_definition, v_patch.old_text, v_patch.new_text);
  end loop;
end;
$patch$;

revoke all on function integration.legacy_sync_schedule_publish(uuid,uuid,text[],jsonb,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_write_draft(uuid,text[],jsonb) from public, anon, authenticated;

-- 3. Restore the units dropped by the legacy sync ------------------------------

do $restore$
declare
  v_cases jsonb;
  v_case jsonb;
  v_customer_id uuid;
  v_source_id uuid;
  v_new_version_id uuid;
  v_restored integer;
begin
  -- The cases are read first: ALTER TABLE below is refused while a loop query
  -- over the plates table is still open in this session.
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
  into v_cases
  from (
    with cur as (
      select c.customer_id, c.customer_name,
             nullif(integration.legacy_sync_schedule_versions(c.customer_id)->>'current', '')::uuid as current_id
      from public.customers c
    ),
    plate_versions as (
      select d.schedule_version_id, count(*) as plates
      from public.customer_schedule_days d
      join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
      join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
      group by d.schedule_version_id
    )
    select cur.customer_id, cur.customer_name, cur.current_id,
           src.schedule_version_id as source_id, src.version_number as source_number,
           src.published_at as source_published_at
    from cur
    join lateral (
      select v.*
      from public.customer_schedule_versions v
      join plate_versions pv on pv.schedule_version_id = v.schedule_version_id
      where v.customer_id = cur.customer_id and v.status in ('PUBLISHED', 'SUPERSEDED')
      order by v.created_at desc
      limit 1
    ) src on true
    where cur.current_id is not null
      and cur.current_id <> src.schedule_version_id
      and not exists (select 1 from plate_versions pv where pv.schedule_version_id = cur.current_id)
      and not exists (select 1 from public.customer_schedule_versions v
                      where v.customer_id = cur.customer_id and v.status = 'DRAFT')
      and not exists (select 1 from public.customer_schedule_versions v
                      where v.customer_id = cur.customer_id and v.created_at > src.created_at
                        and v.status <> 'CANCELLED'
                        and v.source_code is distinct from 'LEGACY_IMPORT')
    order by cur.customer_name
  ) c;

  for v_case in select value from jsonb_array_elements(v_cases) loop
    v_customer_id := (v_case->>'customer_id')::uuid;
    v_source_id := (v_case->>'source_id')::uuid;
    -- New revision: an unchanged copy of the current one (with the fixed copy).
    v_new_version_id := integration.legacy_sync_schedule_publish(
      v_customer_id, (v_case->>'current_id')::uuid, array[]::text[], '{}'::jsonb,
      format('Units restored: the legacy sync dropped the trolley units; copied from revision %s published %s.',
             v_case->>'source_number',
             to_char((v_case->>'source_published_at')::timestamptz at time zone 'Europe/Dublin', 'DD/MM/YYYY HH24:MI')));

    -- The plates trigger accepts only DRAFT parents; this new revision was published
    -- by the call above in this same transaction, so the trigger is paused for it only.
    alter table public.customer_schedule_trolley_plates
      disable trigger customer_schedule_trolley_plates_require_draft;

    with ranked as (
      select d.schedule_version_id, r.schedule_trolley_requirement_id, r.quantity, d.production_weekday,
             coalesce(p.product_type_id::text, '') as product_key, r.trolley_type_id, r.empty_trolley,
             row_number() over (partition by d.schedule_version_id, d.production_weekday, p.product_type_id,
                                             r.trolley_type_id, r.empty_trolley
                                order by r.created_at, r.quantity desc, r.schedule_trolley_requirement_id) as ordinal
      from public.customer_schedule_days d
      join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id and r.active
      left join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
      where d.active and d.schedule_version_id in (v_new_version_id, v_source_id)
    )
    insert into public.customer_schedule_trolley_plates(schedule_trolley_requirement_id, plate_number,
      subunit_ids, instructions, created_by)
    select n.schedule_trolley_requirement_id, pl.plate_number,
      array(select su.subunit_id
            from unnest(pl.subunit_ids) with ordinality as old_subunit(subunit_id, ordinal)
            join public.customer_subunits su on su.subunit_id = old_subunit.subunit_id and su.active
            order by old_subunit.ordinal),
      pl.instructions, pl.created_by
    from ranked n
    join ranked o on o.schedule_version_id = v_source_id
      and o.production_weekday = n.production_weekday and o.product_key = n.product_key
      and o.trolley_type_id = n.trolley_type_id and o.empty_trolley = n.empty_trolley
      and o.ordinal = n.ordinal
    join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = o.schedule_trolley_requirement_id
    where n.schedule_version_id = v_new_version_id
      and pl.plate_number <= n.quantity;
    get diagnostics v_restored = row_count;

    alter table public.customer_schedule_trolley_plates
      enable trigger customer_schedule_trolley_plates_require_draft;

    raise notice 'Units restored for %: % trolley plates in the new revision %.',
      v_case->>'customer_name', v_restored, v_new_version_id;
  end loop;
end;
$restore$;
