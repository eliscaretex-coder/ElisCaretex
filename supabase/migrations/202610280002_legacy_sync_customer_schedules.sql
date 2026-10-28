-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610280002_legacy_sync_customer_schedules
--
-- Sixth part of the nightly legacy sync (owner request 2026-10-28): the
-- customer schedules and the route list are still edited in the legacy
-- CentralDB, so they are synced too. One kind "schedule" with two record types:
--   * ROUTE    Routes sheet, one record per RouteID  -> public.distribution_routes
--   * SCHEDULE CustomerSchedule, one record per CustomerID with all its
--              production days                       -> a new published
--              public.customer_schedule_versions revision
--
-- Rules:
--   * a published schedule is never edited. A legacy change creates a new
--     revision (source LEGACY_IMPORT) effective from the current business
--     date, built from the current V2 revision; the current one is superseded,
--     as Customer Studio does;
--   * same rule as the registers (owner decision 2026-10-27): each value the
--     legacy app changed since the last sync is written, every other value
--     keeps what V2 has. For a customer met for the first time, the baseline is
--     its latest LEGACY_IMPORT revision (the controlled imports of 2026-07-30
--     and 2026-10-23), so legacy changes made since then are written and
--     values corrected by hand in V2 since then are kept and listed
--     (V2_DIFFERS). A customer with no LEGACY_IMPORT revision is only linked
--     and listed;
--   * the delivery weekday is not synced: V2 derives it from the production
--     weekday;
--   * routes: a new legacy route is created; name and colour follow the same
--     rule. KM and hours stay as edited in V2 (Distribution);
--   * a customer with an open draft or a future revision in V2 is held for
--     review, so Customer Studio work is never overwritten;
--   * values kept append-only in integration.legacy_sync_master_states.
--
-- New switch SCHEDULE_IMPORT (seeded OFF, limit 200). The Apps Script control
-- ON/OFF switches it with the others.
-- Apply after 202610270011-0014.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch and provenance roles
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('SCHEDULE_IMPORT', false, 200, 'migration 202610280002',
        'Seeded disabled. Customer schedules and routes from CentralDB. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE','SORTING_WASH_TO_RUN','MOP_ITEM_TO_BATCH',
     'TROLLEY_OUT_TO_STAY','TROLLEY_RETURN_TO_INTAKE',
     'STAFF_SESSION_TO_WORK_SESSION','NOT_WORKING_TO_ATTENDANCE',
     'STAFF_MASTER','CUSTOMER_MASTER','TROLLEY_MASTER','DRIVER_MASTER','VEHICLE_MASTER',
     'ROUTE_MASTER','CUSTOMER_SCHEDULE')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='HOUSEHOLD_TO_REWASH_ENTRY' and target_table='public.finish_rewash_entries') or
    (link_role='REWASH_LINE_TO_LINE' and target_table='public.finish_rewash_lines') or
    (link_role='SORTING_WASH_TO_RUN' and target_table='public.sorting_wash_runs') or
    (link_role='MOP_ITEM_TO_BATCH' and target_table='public.sorting_mop_production_batches') or
    (link_role='TROLLEY_OUT_TO_STAY' and target_table='public.trolley_customer_stays') or
    (link_role='TROLLEY_RETURN_TO_INTAKE' and target_table='public.sorting_trolley_intakes') or
    (link_role='STAFF_SESSION_TO_WORK_SESSION' and target_table='public.work_sessions') or
    (link_role='NOT_WORKING_TO_ATTENDANCE' and target_table='public.finish_daily_staff_attendance') or
    (link_role='STAFF_MASTER' and target_table='public.staff_members') or
    (link_role='CUSTOMER_MASTER' and target_table='public.customers') or
    (link_role='TROLLEY_MASTER' and target_table='public.trolleys') or
    (link_role='DRIVER_MASTER' and target_table='public.distribution_drivers') or
    (link_role='VEHICLE_MASTER' and target_table='public.fleet_vehicles') or
    (link_role='ROUTE_MASTER' and target_table='public.distribution_routes') or
    (link_role='CUSTOMER_SCHEDULE' and target_table='public.customers')
  );

-- ---------------------------------------------------------------------
-- 2. Helpers. A schedule is compared as a flat map, one key per value:
--    "<wd>" (day present), "<wd>.route", "<wd>.window", "<wd>.delivery_order",
--    "<wd>.alert", "<wd>.delivery_notes", "<wd>.products",
--    "<wd>.<PRODUCT>.order", "<wd>.<PRODUCT>.instructions", "<wd>.MOP.variants",
--    "<wd>.trolleys" (owner:type:quantity[:EMPTY], summed per owner and type).
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_weekday(p_value text)
returns smallint
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case lower(btrim(coalesce(p_value,'')))
    when 'monday' then 1 when 'tuesday' then 2 when 'wednesday' then 3 when 'thursday' then 4
    when 'friday' then 5 when 'saturday' then 6 when 'sunday' then 7 end::smallint;
$$;

create or replace function integration.legacy_sync_schedule_key_label(p_key text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[split_part(p_key,'.',1)::integer]
         || case when position('.' in p_key) > 0
                 then ' ' || replace(lower(substr(p_key, position('.' in p_key) + 1)), '_', ' ')
                 else ' day' end;
$$;

-- The legacy CustomerSchedule rows of one customer as a flat map.
create or replace function integration.legacy_sync_schedule_want(p_row jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, staging, pg_temp
as $$
declare
  v_want jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_day jsonb;
  v_wd smallint;
  v_p text;
  v_text text;
  v_num numeric;
  v_window jsonb;
  v_parsed jsonb;
  v_item jsonb;
  v_products text[];
  v_trolleys jsonb;
  v_variants text[];
  v_code text;
  v_owner text;
begin
  if jsonb_typeof(p_row->'days') <> 'array' or jsonb_array_length(p_row->'days') = 0 then
    return jsonb_build_object('want', v_want, 'blockers', integration.legacy_sync_issue('NO_SCHEDULE_ROWS'), 'warnings', v_warnings);
  end if;

  for v_day in select value from jsonb_array_elements(p_row->'days') loop
    v_wd := integration.legacy_sync_weekday(v_day->>'ProductionDay');
    if v_wd is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_PRODUCTION_DAY', coalesce(v_day->>'ProductionDay','(empty)'));
      continue;
    end if;
    if v_want ? v_wd::text then
      v_blockers := v_blockers || integration.legacy_sync_issue('DUPLICATE_PRODUCTION_DAY', v_day->>'ProductionDay');
      continue;
    end if;
    v_want := v_want || jsonb_build_object(v_wd::text, true);

    -- Route: the code only. Name and colour come from the route list.
    v_text := integration.legacy_sync_text(v_day, 'Route');
    v_num := integration.legacy_sync_parse_number(v_text);
    v_want := v_want || jsonb_build_object(v_wd || '.route',
      case when v_num is not null and v_num = trunc(v_num) then trunc(v_num)::text else upper(v_text) end);

    v_text := integration.legacy_sync_text(v_day, 'DeliveryTime');
    if v_text is null then
      v_want := v_want || jsonb_build_object(v_wd || '.window', null);
    else
      v_window := staging.parse_legacy_delivery_window(v_text);
      if v_window->>'status' <> 'PARSED' then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_DELIVERY_TIME', v_text);
      end if;
      v_want := v_want || jsonb_build_object(v_wd || '.window',
        case when v_window->>'status' = 'PARSED'
             then to_char((v_window->>'start_time')::time, 'HH24:MI') || '-' || to_char((v_window->>'end_time')::time, 'HH24:MI') end);
    end if;

    v_text := integration.legacy_sync_text(v_day, 'DeliveryOrder');
    v_num := integration.legacy_sync_parse_number(v_text);
    if v_text is not null and (v_num is null or v_num <> trunc(v_num) or v_num < 1) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_DELIVERY_ORDER', v_text);
    end if;
    v_want := v_want || jsonb_build_object(v_wd || '.delivery_order', case when v_num >= 1 then trunc(v_num)::integer end);
    v_want := v_want || jsonb_build_object(v_wd || '.alert', integration.legacy_sync_text(v_day, 'Information'));
    v_want := v_want || jsonb_build_object(v_wd || '.delivery_notes', integration.legacy_sync_text(v_day, 'DeliveryNotes'));

    -- Products: a production order means the product is made that day.
    v_products := '{}';
    foreach v_p in array array['CLOTHES','MOP'] loop
      v_text := integration.legacy_sync_text(v_day, case v_p when 'CLOTHES' then 'ClothesOrder' else 'MopOrder' end);
      if v_text is null then continue; end if;
      v_num := integration.legacy_sync_parse_number(v_text);
      if v_num is null or v_num <> trunc(v_num) or v_num < 1 then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_PRODUCTION_ORDER', v_p || ' ' || v_text);
        continue;
      end if;
      v_products := v_products || v_p;
      v_want := v_want || jsonb_build_object(
        v_wd || '.' || v_p || '.order', trunc(v_num)::integer,
        v_wd || '.' || v_p || '.instructions',
          integration.legacy_sync_text(v_day, case v_p when 'CLOTHES' then 'ClothesNotes' else 'MopInstructions' end));
    end loop;
    if cardinality(v_products) = 0 then
      v_blockers := v_blockers || integration.legacy_sync_issue('NO_PRODUCT_ON_DAY', v_day->>'ProductionDay');
    end if;
    v_want := v_want || jsonb_build_object(v_wd || '.products', to_jsonb(v_products));

    -- MOP products, through the owner-approved list of 2026-07-30.
    v_variants := '{}';
    v_text := integration.legacy_sync_text(v_day, 'MopProducts');
    if v_text is not null then
      for v_p in select btrim(x) from regexp_split_to_table(v_text, '\s*;\s*') x where btrim(x) <> '' loop
        select m.proposed_variant_code into v_code from staging.legacy_mop_variant_mapping m
        where upper(btrim(m.legacy_value)) = upper(v_p) and m.owner_confirmed and not m.review_required;
        if v_code is null then
          v_blockers := v_blockers || integration.legacy_sync_issue('UNKNOWN_MOP_PRODUCT', v_p);
        elsif not v_code = any(v_variants) then
          v_variants := v_variants || v_code;
        end if;
      end loop;
    end if;
    if 'MOP' = any(v_products) then
      v_want := v_want || jsonb_build_object(v_wd || '.MOP.variants',
        (select coalesce(jsonb_agg(c order by c), '[]'::jsonb) from unnest(v_variants) c));
    elsif cardinality(v_variants) > 0 then
      v_warnings := v_warnings || integration.legacy_sync_issue('MOP_PRODUCTS_WITHOUT_MOP_ORDER', v_day->>'ProductionDay');
    end if;

    -- Trolleys: QtyClothes belongs to Clothes, TrolleyMop to MOP. Quantity 0 means none.
    v_trolleys := '[]'::jsonb;
    foreach v_owner in array array['CLOTHES','MOP'] loop
      v_text := integration.legacy_sync_text(v_day, case v_owner when 'CLOTHES' then 'QtyClothes' else 'TrolleyMop' end);
      if v_text is null then continue; end if;
      v_parsed := staging.parse_legacy_trolley_text(v_text);
      if v_parsed->>'status' not in ('PARSED','NONE','BLANK') then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_TROLLEY_TEXT', v_owner || ' ' || v_text);
        continue;
      end if;
      for v_item in select value from jsonb_array_elements(coalesce(v_parsed->'items','[]'::jsonb)) loop
        continue when coalesce((v_item->>'quantity')::integer, 0) <= 0;
        if not v_owner = any(v_products) then
          v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_WITHOUT_PRODUCT', v_owner || ' ' || v_text);
          exit;
        end if;
        v_trolleys := v_trolleys || jsonb_build_array(jsonb_build_object(
          'owner', v_owner, 'type', v_item->>'trolley_type_code',
          'quantity', (v_item->>'quantity')::integer, 'empty', coalesce((v_item->>'empty_trolley')::boolean, false)));
      end loop;
    end loop;
    v_want := v_want || jsonb_build_object(v_wd || '.trolleys', integration.legacy_sync_trolley_keys(v_trolleys));
  end loop;

  return jsonb_build_object('want', v_want, 'blockers', v_blockers, 'warnings', v_warnings);
end;
$$;

-- Trolley requirements as sorted "OWNER:TYPE:QTY[:EMPTY]" keys, summed per owner, type and empty flag.
create or replace function integration.legacy_sync_trolley_keys(p_items jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from (
    select (i->>'owner') || ':' || (i->>'type') || ':' || sum((i->>'quantity')::integer)
           || case when (i->>'empty')::boolean then ':EMPTY' else '' end as k
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
    group by i->>'owner', i->>'type', (i->>'empty')::boolean) x;
$$;

-- One V2 schedule revision as the same flat map (active days, products and trolleys).
create or replace function integration.legacy_sync_schedule_have(p_version_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select coalesce((
    select jsonb_object_agg(k, v) from (
      select d.production_weekday::text as k, 'true'::jsonb as v
      from public.customer_schedule_days d where d.schedule_version_id = p_version_id and d.active
      union all
      select d.production_weekday || '.' || f.k, f.v
      from public.customer_schedule_days d
      left join public.distribution_routes r on r.route_id = d.default_route_id
      cross join lateral (values
        ('route', to_jsonb(r.route_code)),
        ('window', to_jsonb(case when d.delivery_window_start is not null and d.delivery_window_end is not null
           then to_char(d.delivery_window_start,'HH24:MI') || '-' || to_char(d.delivery_window_end,'HH24:MI') end)),
        ('delivery_order', to_jsonb(d.delivery_order)),
        ('alert', to_jsonb(nullif(btrim(d.day_alert), ''))),
        ('delivery_notes', to_jsonb(nullif(btrim(d.distribution_instructions), ''))),
        ('products', (select coalesce(jsonb_agg(pt.product_code order by pt.product_code), '[]'::jsonb)
                      from public.customer_schedule_products p join public.product_types pt using (product_type_id)
                      where p.schedule_day_id = d.schedule_day_id and p.active)),
        ('trolleys', (select integration.legacy_sync_trolley_keys(coalesce(jsonb_agg(jsonb_build_object(
                         'owner', opt.product_code, 'type', tt.trolley_type_code, 'quantity', t.quantity, 'empty', t.empty_trolley)), '[]'::jsonb))
                      from public.customer_schedule_trolley_requirements t
                      join public.trolley_types tt using (trolley_type_id)
                      join public.customer_schedule_products op on op.schedule_product_id = t.owner_schedule_product_id
                      join public.product_types opt on opt.product_type_id = op.product_type_id
                      where t.schedule_day_id = d.schedule_day_id and t.active))
      ) f(k, v)
      where d.schedule_version_id = p_version_id and d.active
      union all
      select d.production_weekday || '.' || pt.product_code || '.' || f.k, f.v
      from public.customer_schedule_days d
      join public.customer_schedule_products p on p.schedule_day_id = d.schedule_day_id and p.active
      join public.product_types pt using (product_type_id)
      cross join lateral (values
        ('order', to_jsonb(p.production_order)),
        ('instructions', to_jsonb(nullif(btrim(p.production_instructions), '')))
      ) f(k, v)
      where d.schedule_version_id = p_version_id and d.active
      union all
      select d.production_weekday || '.MOP.variants',
             (select coalesce(jsonb_agg(pv.variant_code order by pv.variant_code), '[]'::jsonb)
              from public.customer_schedule_product_variants spv
              join public.product_variants pv using (product_variant_id)
              where spv.schedule_product_id = p.schedule_product_id)
      from public.customer_schedule_days d
      join public.customer_schedule_products p on p.schedule_day_id = d.schedule_day_id and p.active
      join public.product_types pt on pt.product_type_id = p.product_type_id and pt.product_code = 'MOP'
      where d.schedule_version_id = p_version_id and d.active
    ) x), '{}'::jsonb);
$$;

-- The revision V2 uses today, a future one, and the open draft.
create or replace function integration.legacy_sync_schedule_versions(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select jsonb_build_object(
    'current', (select v.schedule_version_id from public.customer_schedule_versions v
                where v.customer_id = p_customer_id and v.status = 'PUBLISHED'
                  and v.effective_from <= public.current_business_date()
                  and (v.effective_until is null or v.effective_until >= public.current_business_date())
                order by v.effective_from desc, v.version_number desc limit 1),
    'future', (select v.schedule_version_id from public.customer_schedule_versions v
               where v.customer_id = p_customer_id and v.status = 'PUBLISHED'
                 and v.effective_from > public.current_business_date()
               order by v.effective_from limit 1),
    'draft', (select v.schedule_version_id from public.customer_schedule_versions v
              where v.customer_id = p_customer_id and v.status = 'DRAFT' limit 1),
    'legacy_import', (select v.schedule_version_id from public.customer_schedule_versions v
                      where v.customer_id = p_customer_id and v.source_code = 'LEGACY_IMPORT'
                        and v.status in ('PUBLISHED','SUPERSEDED')
                      order by v.version_number desc limit 1));
$$;

-- ---------------------------------------------------------------------
-- 3. Plans (read-only)
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_route(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_id text := upper(integration.legacy_sync_text(p_record,'source_record_id'));
  v_num numeric;
  v_want jsonb;
  v_have jsonb;
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_route public.distribution_routes%rowtype;
  v_link integration.legacy_sync_record_links%rowtype;
  v_state integration.legacy_sync_master_states%rowtype;
  v_apply text[];
  v_differs text[];
  v_action text;
  v_color text;
begin
  v_num := integration.legacy_sync_parse_number(v_id);
  if v_num is not null and v_num = trunc(v_num) then v_id := trunc(v_num)::text; end if;
  if v_row is null or v_id is null or length(v_id) > 40 then
    return jsonb_build_object('outcome','BLOCKED','record_type','ROUTE','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','ROUTE'),'warnings','[]'::jsonb);
  end if;

  v_color := lower(integration.legacy_sync_text(v_row,'Colour'));
  if v_color is not null and v_color !~ '^#[0-9a-f]{6}$' then
    v_warnings := v_warnings || integration.legacy_sync_issue('INVALID_ROUTE_COLOUR', v_color);
    v_color := null;
  end if;
  v_want := jsonb_build_object(
    'display_name', coalesce(integration.legacy_sync_text(v_row,'DisplayName'), 'Route ' || v_id),
    'route_color', v_color);
  v_fp := integration.legacy_sync_fingerprint(v_want);

  select * into v_route from public.distribution_routes r
  where upper(r.route_code) = v_id and r.deleted_at is null;
  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system='CENTRALDB' and l.source_table='Routes' and l.source_record_id=v_id
    and l.link_role='ROUTE_MASTER' and l.source_line_key='';
  if v_link.link_id is not null then
    select * into v_route from public.distribution_routes r where r.route_id = v_link.target_id;
  end if;

  if v_route.route_id is not null then
    v_have := jsonb_build_object('display_name', v_route.display_name, 'route_color', lower(v_route.route_color));
    if not v_route.active then
      return jsonb_build_object('outcome','SKIPPED','record_type','ROUTE','source_record_id',v_id,'fingerprint',v_fp,
        'skip_reason','INACTIVE_IN_V2','target_id',v_route.route_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
  end if;

  if v_link.link_id is not null then
    select * into v_state from integration.legacy_sync_master_states s
    where s.source_system='CENTRALDB' and s.source_table='Routes' and s.source_record_id=v_id
    order by s.state_id desc limit 1;
    if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type','ROUTE','source_record_id',v_id,
        'fingerprint',v_fp,'target_id',v_route.route_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
    select array_agg(k order by k) into v_apply from jsonb_object_keys(v_want) k
    where (v_want->k) is distinct from coalesce(v_state.synced->k, 'null'::jsonb)
      and (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb)
      and v_want->k <> 'null'::jsonb;
    v_action := case when v_apply is null then 'RELINK' else 'UPDATE' end;
  elsif v_route.route_id is not null then
    v_action := 'ADOPT';
    select array_agg(k order by k) into v_differs from jsonb_object_keys(v_want) k
    where v_want->k <> 'null'::jsonb and (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb);
    if v_differs is not null then
      v_warnings := v_warnings || integration.legacy_sync_issue('V2_DIFFERS',
        (select string_agg(k || ': V2 ' || coalesce(v_have->>k,'-') || ' / legacy ' || coalesce(v_want->>k,'-'), '; ')
         from unnest(v_differs) k));
    end if;
  else
    v_action := 'CREATE';
    v_apply := array['display_name','route_color'];
  end if;

  return jsonb_build_object('outcome','READY','record_type','ROUTE','source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'target_id',v_route.route_id,
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k,'null'::jsonb), 'legacy', v_want->k)), '{}'::jsonb)
                from unnest(coalesce(v_apply, '{}'::text[])) k),
    'want', v_want, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

create or replace function integration.legacy_sync_plan_schedule(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_built jsonb;
  v_want jsonb;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb;
  v_customer public.customers%rowtype;
  v_link integration.legacy_sync_record_links%rowtype;
  v_state integration.legacy_sync_master_states%rowtype;
  v_versions jsonb;
  v_current uuid;
  v_have jsonb := '{}'::jsonb;
  v_base jsonb;
  v_merged jsonb;
  v_keys text[];
  v_apply text[];
  v_differs text[];
  v_action text;
  v_k text;
  v_wd text;
  v_p text;
  v_t text;
begin
  if v_row is null or v_id is null or length(v_id) > 160 then
    return jsonb_build_object('outcome','BLOCKED','record_type','SCHEDULE','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','SCHEDULE'),'warnings','[]'::jsonb);
  end if;

  v_built := integration.legacy_sync_schedule_want(v_row);
  v_want := v_built->'want';
  v_blockers := v_built->'blockers';
  v_warnings := v_built->'warnings';
  v_fp := integration.legacy_sync_fingerprint(v_want);

  select c.* into v_customer from public.customers c
  where c.customer_code = upper(v_id) or c.legacy_metadata->>'legacy_customer_id' = v_id
  order by (c.customer_code = upper(v_id)) desc limit 1;
  if v_customer.customer_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_NOT_IN_V2', v_id);
  elsif v_customer.deleted_at is not null or not v_customer.active then
    return jsonb_build_object('outcome','SKIPPED','record_type','SCHEDULE','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','CUSTOMER_INACTIVE_IN_V2','target_id',v_customer.customer_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type','SCHEDULE','source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings,'target_id',v_customer.customer_id);
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system='CENTRALDB' and l.source_table='CustomerSchedule' and l.source_record_id=v_id
    and l.link_role='CUSTOMER_SCHEDULE' and l.source_line_key='';
  if v_link.link_id is not null then
    select * into v_state from integration.legacy_sync_master_states s
    where s.source_system='CENTRALDB' and s.source_table='CustomerSchedule' and s.source_record_id=v_id
    order by s.state_id desc limit 1;
    if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type','SCHEDULE','source_record_id',v_id,
        'fingerprint',v_fp,'target_id',v_customer.customer_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
  end if;

  v_versions := integration.legacy_sync_schedule_versions(v_customer.customer_id);
  v_current := nullif(v_versions->>'current','')::uuid;
  if v_current is not null then
    v_have := integration.legacy_sync_schedule_have(v_current);
  end if;

  -- Baseline: what the legacy app said last time.
  if v_state.state_id is not null then
    v_base := v_state.synced;
  elsif v_versions->>'legacy_import' is not null then
    v_base := integration.legacy_sync_schedule_have((v_versions->>'legacy_import')::uuid);
  end if;

  select array_agg(distinct k) into v_keys from (
    select jsonb_object_keys(v_want) k union select jsonb_object_keys(v_have)
    union select jsonb_object_keys(coalesce(v_base, '{}'::jsonb))) x;

  if v_current is null then
    v_action := 'CREATE';
    select array_agg(k order by k) into v_apply from jsonb_object_keys(v_want) k;
  else
    if v_base is not null then
      -- Values the legacy app changed since the baseline that V2 does not have yet.
      select array_agg(k order by k) into v_apply from unnest(v_keys) k
      where coalesce(v_want->k,'null'::jsonb) is distinct from coalesce(v_base->k,'null'::jsonb)
        and coalesce(v_want->k,'null'::jsonb) is distinct from coalesce(v_have->k,'null'::jsonb);
    end if;
    v_action := case when v_apply is not null then 'UPDATE' when v_link.link_id is null then 'ADOPT' else 'RELINK' end;
    if v_link.link_id is null then
      select array_agg(k order by k) into v_differs from unnest(v_keys) k
      where coalesce(v_want->k,'null'::jsonb) is distinct from coalesce(v_have->k,'null'::jsonb)
        and not k = any(coalesce(v_apply, '{}'::text[]));
      if v_differs is not null then
        v_warnings := v_warnings || integration.legacy_sync_issue('V2_DIFFERS',
          (select string_agg(integration.legacy_sync_schedule_key_label(k) || ': V2 ' || coalesce(v_have->>k,'-')
                             || ' / legacy ' || coalesce(v_want->>k,'-'), '; ' order by k)
           from unnest(v_differs) k));
      end if;
    end if;
  end if;

  if v_action in ('CREATE','UPDATE') then
    if v_versions->>'draft' is not null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SCHEDULE_DRAFT_OPEN_IN_V2');
    end if;
    if v_versions->>'future' is not null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SCHEDULE_FUTURE_VERSION_IN_V2');
    end if;

    -- The revision V2 would publish: V2 values with the legacy changes on top.
    v_merged := v_have;
    foreach v_k in array v_apply loop
      v_merged := case when v_want ? v_k then v_merged || jsonb_build_object(v_k, v_want->v_k) else v_merged - v_k end;
    end loop;
    if not exists (select 1 from jsonb_object_keys(v_merged) k where k ~ '^[1-7]$') then
      v_blockers := v_blockers || integration.legacy_sync_issue('NO_PRODUCTION_DAY');
    end if;
    for v_wd in select k from jsonb_object_keys(v_merged) k where k ~ '^[1-7]$' loop
      if jsonb_array_length(coalesce(v_merged->(v_wd || '.products'), '[]'::jsonb)) = 0 then
        v_blockers := v_blockers || integration.legacy_sync_issue('NO_PRODUCT_ON_DAY', integration.legacy_sync_schedule_key_label(v_wd));
      end if;
      for v_p in select jsonb_array_elements_text(coalesce(v_merged->(v_wd || '.products'), '[]'::jsonb)) loop
        if not exists (select 1 from public.customer_product_services s join public.product_types pt using (product_type_id)
                       where s.customer_id = v_customer.customer_id and pt.product_code = v_p and s.active and s.deleted_at is null
                         and s.effective_from <= public.current_business_date()
                         and (s.effective_until is null or s.effective_until >= public.current_business_date())) then
          v_blockers := v_blockers || integration.legacy_sync_issue('PRODUCT_NOT_ENABLED', v_p);
        end if;
      end loop;
      for v_t in select jsonb_array_elements_text(coalesce(v_merged->(v_wd || '.trolleys'), '[]'::jsonb)) loop
        if not coalesce(v_merged->(v_wd || '.products'), '[]'::jsonb) ? split_part(v_t, ':', 1) then
          v_blockers := v_blockers || integration.legacy_sync_issue('SCHEDULE_CONFLICT',
            integration.legacy_sync_schedule_key_label(v_wd) || ' trolley ' || v_t || ' without its product');
        end if;
      end loop;
      if v_merged->>(v_wd || '.route') is not null and not exists (
          select 1 from public.distribution_routes r where r.route_code = v_merged->>(v_wd || '.route')
            and r.active and r.allow_as_default and r.deleted_at is null) then
        v_blockers := v_blockers || integration.legacy_sync_issue('ROUTE_NOT_IN_V2', v_merged->>(v_wd || '.route'));
      end if;
    end loop;
    select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
    from (select distinct b from jsonb_array_elements(v_blockers) b) x;

    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type','SCHEDULE','source_record_id',v_id,'fingerprint',v_fp,
        'action',v_action,'blockers',v_blockers,'warnings',v_warnings,'target_id',v_customer.customer_id);
    end if;
  end if;

  return jsonb_build_object('outcome','READY','record_type','SCHEDULE','source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'target_id',v_customer.customer_id,'current_version_id',v_current,
    'baseline', case when v_state.state_id is not null then 'LAST_SYNC' when v_base is not null then 'LEGACY_IMPORT' end,
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k,'null'::jsonb),
                                                                         'legacy', coalesce(v_want->k,'null'::jsonb))), '{}'::jsonb)
                from unnest(coalesce(v_apply, '{}'::text[])) k),
    'want', v_want, 'merged', v_merged, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

create or replace function integration.legacy_sync_plan_schedule_record(p_record jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select case upper(coalesce(p_record->>'record_type',''))
    when 'ROUTE' then integration.legacy_sync_plan_route(p_record)
    when 'SCHEDULE' then integration.legacy_sync_plan_schedule(p_record)
    else jsonb_build_object('outcome','BLOCKED','record_type',upper(coalesce(p_record->>'record_type','')),
      'source_record_id',p_record->>'source_record_id',
      'blockers',integration.legacy_sync_issue('INVALID_RECORD', p_record->>'record_type'),'warnings','[]'::jsonb)
  end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run: 1-60 records. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_schedule_dry_run(p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_plans jsonb := '[]'::jsonb;
  v_record jsonb;
  v_plan jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array'
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 60 then
    raise exception using errcode='22023', message='Send between 1 and 60 legacy schedule or route records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_schedule_record(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id'
          and o->>'record_type' is not distinct from v_plan->>'record_type') > 1
       and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH'));
    end if;
    v_out := v_out || jsonb_build_array(v_plan - 'want' - 'merged');
  end loop;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'actions', (select coalesce(jsonb_object_agg(a, n),'{}'::jsonb) from (
        select (o->>'record_type')||':'||(o->>'action') as a, count(*) as n from jsonb_array_elements(v_out) o
        where o->>'outcome'='READY' group by 1) x),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'skipped', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='SKIPPED'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'warning_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select w->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'warnings','[]'::jsonb)) w
        group by 1) x),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Writers
-- ---------------------------------------------------------------------

-- Removes one product of a DRAFT day, with its variants and the trolleys it owns or shares.
create or replace function integration.legacy_sync_schedule_drop_product(p_schedule_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  delete from public.customer_schedule_trolley_requirement_products m
  where m.schedule_product_id = p_schedule_product_id
     or m.schedule_trolley_requirement_id in (select t.schedule_trolley_requirement_id
                                              from public.customer_schedule_trolley_requirements t
                                              where t.owner_schedule_product_id = p_schedule_product_id);
  delete from public.customer_schedule_trolley_requirements t where t.owner_schedule_product_id = p_schedule_product_id;
  delete from public.customer_schedule_product_variants v where v.schedule_product_id = p_schedule_product_id;
  delete from public.customer_schedule_products p where p.schedule_product_id = p_schedule_product_id;
end;
$$;

-- Writes the values p_keys of p_merged onto the DRAFT revision p_version_id.
create or replace function integration.legacy_sync_schedule_write_draft(p_version_id uuid, p_keys text[], p_merged jsonb)
returns void
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_wd text;
  v_day_id uuid;
  v_p text;
  v_t text;
  v_product_id uuid;
  v_req_id uuid;
  v_new_day boolean;
  v_window text;
begin
  for v_wd in select distinct split_part(k, '.', 1) from unnest(p_keys) k order by 1 loop
    select d.schedule_day_id into v_day_id from public.customer_schedule_days d
    where d.schedule_version_id = p_version_id and d.production_weekday = v_wd::smallint;

    -- Day removed in the legacy app.
    if not p_merged ? v_wd then
      if v_day_id is not null then
        for v_product_id in select p.schedule_product_id from public.customer_schedule_products p where p.schedule_day_id = v_day_id loop
          perform integration.legacy_sync_schedule_drop_product(v_product_id);
        end loop;
        delete from public.customer_schedule_trolley_requirements t where t.schedule_day_id = v_day_id;
        delete from public.customer_schedule_days d where d.schedule_day_id = v_day_id;
      end if;
      continue;
    end if;

    v_new_day := v_day_id is null;
    if v_new_day then
      insert into public.customer_schedule_days(schedule_version_id, production_weekday, active, metadata)
      values (p_version_id, v_wd::smallint, true, jsonb_build_object('source','LEGACY_SYNC'))
      returning schedule_day_id into v_day_id;
    end if;

    if v_new_day or (v_wd || '.route') = any(p_keys) then
      update public.customer_schedule_days d
      set default_route_id = (select r.route_id from public.distribution_routes r
                              where r.route_code = p_merged->>(v_wd || '.route') and r.deleted_at is null)
      where d.schedule_day_id = v_day_id;
    end if;
    if v_new_day or (v_wd || '.window') = any(p_keys) then
      v_window := p_merged->>(v_wd || '.window');
      update public.customer_schedule_days d
      set delivery_window_start = case when v_window is not null then split_part(v_window, '-', 1)::time end,
          delivery_window_end = case when v_window is not null then split_part(v_window, '-', 2)::time end
      where d.schedule_day_id = v_day_id;
    end if;
    if v_new_day or (v_wd || '.delivery_order') = any(p_keys) then
      update public.customer_schedule_days d set delivery_order = (p_merged->>(v_wd || '.delivery_order'))::integer
      where d.schedule_day_id = v_day_id;
    end if;
    if v_new_day or (v_wd || '.alert') = any(p_keys) then
      update public.customer_schedule_days d set day_alert = p_merged->>(v_wd || '.alert') where d.schedule_day_id = v_day_id;
    end if;
    if v_new_day or (v_wd || '.delivery_notes') = any(p_keys) then
      update public.customer_schedule_days d set distribution_instructions = p_merged->>(v_wd || '.delivery_notes')
      where d.schedule_day_id = v_day_id;
    end if;

    -- Products made that day.
    if v_new_day or (v_wd || '.products') = any(p_keys) then
      for v_product_id in
        select p.schedule_product_id from public.customer_schedule_products p join public.product_types pt using (product_type_id)
        where p.schedule_day_id = v_day_id and not coalesce(p_merged->(v_wd || '.products'), '[]'::jsonb) ? pt.product_code
      loop
        perform integration.legacy_sync_schedule_drop_product(v_product_id);
      end loop;
      insert into public.customer_schedule_products(schedule_day_id, product_type_id, active, metadata)
      select v_day_id, pt.product_type_id, true, jsonb_build_object('source','LEGACY_SYNC')
      from jsonb_array_elements_text(coalesce(p_merged->(v_wd || '.products'), '[]'::jsonb)) code
      join public.product_types pt on pt.product_code = code
      where not exists (select 1 from public.customer_schedule_products p
                        where p.schedule_day_id = v_day_id and p.product_type_id = pt.product_type_id);
    end if;

    for v_p in select jsonb_array_elements_text(coalesce(p_merged->(v_wd || '.products'), '[]'::jsonb)) loop
      select p.schedule_product_id into v_product_id from public.customer_schedule_products p
      join public.product_types pt using (product_type_id)
      where p.schedule_day_id = v_day_id and pt.product_code = v_p;
      if v_new_day or (v_wd || '.' || v_p || '.order') = any(p_keys) or (v_wd || '.products') = any(p_keys) then
        update public.customer_schedule_products p set production_order = (p_merged->>(v_wd || '.' || v_p || '.order'))::integer
        where p.schedule_product_id = v_product_id
          and p_merged ? (v_wd || '.' || v_p || '.order');
      end if;
      if v_new_day or (v_wd || '.' || v_p || '.instructions') = any(p_keys) or (v_wd || '.products') = any(p_keys) then
        update public.customer_schedule_products p set production_instructions = p_merged->>(v_wd || '.' || v_p || '.instructions')
        where p.schedule_product_id = v_product_id
          and p_merged ? (v_wd || '.' || v_p || '.instructions');
      end if;
      if v_p = 'MOP' and (v_new_day or (v_wd || '.MOP.variants') = any(p_keys) or (v_wd || '.products') = any(p_keys))
         and p_merged ? (v_wd || '.MOP.variants') then
        delete from public.customer_schedule_product_variants v where v.schedule_product_id = v_product_id;
        insert into public.customer_schedule_product_variants(schedule_product_id, product_variant_id)
        select v_product_id, pv.product_variant_id
        from jsonb_array_elements_text(p_merged->(v_wd || '.MOP.variants')) code
        join public.product_variants pv on pv.variant_code = code
        join public.product_types pt on pt.product_type_id = pv.product_type_id and pt.product_code = 'MOP';
      end if;
    end loop;

    -- Trolleys: rebuilt from the legacy text; each one serves the product that owns it.
    if v_new_day or (v_wd || '.trolleys') = any(p_keys) then
      delete from public.customer_schedule_trolley_requirement_products m
      where m.schedule_trolley_requirement_id in (select t.schedule_trolley_requirement_id
                                                  from public.customer_schedule_trolley_requirements t
                                                  where t.schedule_day_id = v_day_id);
      delete from public.customer_schedule_trolley_requirements t where t.schedule_day_id = v_day_id;
      for v_t in select jsonb_array_elements_text(coalesce(p_merged->(v_wd || '.trolleys'), '[]'::jsonb)) loop
        select p.schedule_product_id into v_product_id from public.customer_schedule_products p
        join public.product_types pt using (product_type_id)
        where p.schedule_day_id = v_day_id and pt.product_code = split_part(v_t, ':', 1);
        insert into public.customer_schedule_trolley_requirements(schedule_day_id, trolley_type_id,
          owner_schedule_product_id, quantity, empty_trolley, active, metadata)
        values (v_day_id, (select tt.trolley_type_id from public.trolley_types tt where tt.trolley_type_code = split_part(v_t, ':', 2)),
                v_product_id, split_part(v_t, ':', 3)::integer, split_part(v_t, ':', 4) = 'EMPTY', true,
                jsonb_build_object('source','LEGACY_SYNC'))
        returning schedule_trolley_requirement_id into v_req_id;
        insert into public.customer_schedule_trolley_requirement_products(schedule_trolley_requirement_id, schedule_product_id)
        values (v_req_id, v_product_id);
      end loop;
    end if;
  end loop;
end;
$$;

-- New revision for one customer: a DRAFT copy of the current revision (as Customer Studio
-- does), the legacy changes on it, the publication checks, then publication.
create or replace function integration.legacy_sync_schedule_publish(
  p_customer_id uuid, p_current_version_id uuid, p_keys text[], p_merged jsonb, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_today date := public.current_business_date();
  v_version_id uuid;
  v_number integer;
  v_old_day record;
  v_old_product record;
  v_old_req record;
  v_new_day_id uuid;
  v_new_product_id uuid;
  v_new_req_id uuid;
  v_day_map jsonb := '{}'::jsonb;
  v_product_map jsonb := '{}'::jsonb;
  v_problem text;
begin
  perform 1 from public.customers c where c.customer_id = p_customer_id for update;
  if exists (select 1 from public.customer_schedule_versions v where v.customer_id = p_customer_id and v.status = 'DRAFT') then
    raise exception using errcode='55000', message='This customer has an open schedule draft in V2.';
  end if;
  if p_current_version_id is distinct from nullif(integration.legacy_sync_schedule_versions(p_customer_id)->>'current','')::uuid then
    raise exception using errcode='40001', message='The V2 schedule changed during import. Retry.';
  end if;

  select coalesce(max(v.version_number), 0) + 1 into v_number
  from public.customer_schedule_versions v where v.customer_id = p_customer_id;

  insert into public.customer_schedule_versions(customer_id, version_number, status, effective_from,
    based_on_version_id, source_code, change_reason)
  values (p_customer_id, v_number, 'DRAFT', v_today, p_current_version_id, 'LEGACY_IMPORT', p_reason)
  returning schedule_version_id into v_version_id;

  if p_current_version_id is not null then
    for v_old_day in select * from public.customer_schedule_days d
                     where d.schedule_version_id = p_current_version_id and d.active order by d.production_weekday loop
      insert into public.customer_schedule_days(schedule_version_id, production_weekday, delivery_weekday, default_route_id,
        delivery_window_start, delivery_window_end, delivery_order, day_alert, distribution_instructions, active, metadata)
      values (v_version_id, v_old_day.production_weekday, v_old_day.delivery_weekday, v_old_day.default_route_id,
        v_old_day.delivery_window_start, v_old_day.delivery_window_end, v_old_day.delivery_order, v_old_day.day_alert,
        v_old_day.distribution_instructions, true, v_old_day.metadata)
      returning schedule_day_id into v_new_day_id;
      v_day_map := v_day_map || jsonb_build_object(v_old_day.schedule_day_id::text, v_new_day_id::text);

      for v_old_product in select * from public.customer_schedule_products p
                           where p.schedule_day_id = v_old_day.schedule_day_id and p.active loop
        insert into public.customer_schedule_products(schedule_day_id, product_type_id, production_order, expected_kg,
          expected_units, production_instructions, active, metadata)
        values (v_new_day_id, v_old_product.product_type_id, v_old_product.production_order, v_old_product.expected_kg,
          v_old_product.expected_units, v_old_product.production_instructions, true, v_old_product.metadata)
        returning schedule_product_id into v_new_product_id;
        v_product_map := v_product_map || jsonb_build_object(v_old_product.schedule_product_id::text, v_new_product_id::text);
        insert into public.customer_schedule_product_variants(schedule_product_id, product_variant_id)
        select v_new_product_id, v.product_variant_id from public.customer_schedule_product_variants v
        where v.schedule_product_id = v_old_product.schedule_product_id;
      end loop;
    end loop;

    for v_old_req in select t.* from public.customer_schedule_trolley_requirements t
                     join public.customer_schedule_days d on d.schedule_day_id = t.schedule_day_id
                     where d.schedule_version_id = p_current_version_id and d.active and t.active
                       and v_product_map ? t.owner_schedule_product_id::text
                     order by t.created_at loop
      insert into public.customer_schedule_trolley_requirements(schedule_day_id, trolley_type_id, owner_schedule_product_id,
        quantity, empty_trolley, notes, active, metadata)
      values ((v_day_map->>v_old_req.schedule_day_id::text)::uuid, v_old_req.trolley_type_id,
        (v_product_map->>v_old_req.owner_schedule_product_id::text)::uuid, v_old_req.quantity, v_old_req.empty_trolley,
        v_old_req.notes, true, v_old_req.metadata)
      returning schedule_trolley_requirement_id into v_new_req_id;
      insert into public.customer_schedule_trolley_requirement_products(schedule_trolley_requirement_id, schedule_product_id)
      select v_new_req_id, (v_product_map->>m.schedule_product_id::text)::uuid
      from public.customer_schedule_trolley_requirement_products m
      where m.schedule_trolley_requirement_id = v_old_req.schedule_trolley_requirement_id
        and v_product_map ? m.schedule_product_id::text;
    end loop;
  end if;

  perform integration.legacy_sync_schedule_write_draft(v_version_id, p_keys, p_merged);

  -- The checks of publish_customer_schedule.
  select case
    when not exists (select 1 from public.customer_schedule_days d where d.schedule_version_id = v_version_id and d.active)
      then 'The schedule must contain at least one active production day.'
    when exists (select 1 from public.customer_schedule_days d where d.schedule_version_id = v_version_id and d.active
                   and not exists (select 1 from public.customer_schedule_products p where p.schedule_day_id = d.schedule_day_id and p.active))
      then 'Every active production day must contain at least one active product.'
    when exists (select 1 from public.customer_schedule_products p
                 join public.customer_schedule_days d on d.schedule_day_id = p.schedule_day_id
                 left join public.customer_product_services s on s.customer_id = p_customer_id and s.product_type_id = p.product_type_id
                   and s.active and s.deleted_at is null and s.effective_from <= v_today
                   and (s.effective_until is null or s.effective_until >= v_today)
                 where d.schedule_version_id = v_version_id and d.active and p.active and s.customer_product_service_id is null)
      then 'The schedule contains a product that is not enabled for this customer.'
    when exists (select 1 from public.customer_schedule_days d join public.distribution_routes r on r.route_id = d.default_route_id
                 where d.schedule_version_id = v_version_id and d.active
                   and (not r.active or r.deleted_at is not null or not r.allow_as_default))
      then 'The schedule contains an inactive route or a route that cannot be used as a default route.'
    when exists (select 1 from public.customer_schedule_trolley_requirements t
                 join public.customer_schedule_days d on d.schedule_day_id = t.schedule_day_id
                 left join public.trolley_types tt on tt.trolley_type_id = t.trolley_type_id
                 where d.schedule_version_id = v_version_id and t.active
                   and (tt.trolley_type_id is null or not tt.active or not tt.allowed_in_customer_schedule or tt.deleted_at is not null))
      then 'The schedule contains an inactive or missing trolley type.'
    when exists (select 1 from public.customer_schedule_trolley_requirements t
                 join public.customer_schedule_days d on d.schedule_day_id = t.schedule_day_id
                 where d.schedule_version_id = v_version_id and t.active
                   and not exists (select 1 from public.customer_schedule_trolley_requirement_products m
                                   where m.schedule_trolley_requirement_id = t.schedule_trolley_requirement_id
                                     and m.schedule_product_id = t.owner_schedule_product_id))
      then 'The trolley owner product must also be included in the products served by that trolley.'
  end into v_problem;
  if v_problem is not null then
    raise exception using errcode='23514', message=v_problem;
  end if;

  -- As publish_customer_schedule: the revisions it replaces from today are superseded.
  update public.customer_schedule_versions v
  set status = 'SUPERSEDED',
      effective_until = case when v.effective_from < v_today
                             then least(coalesce(v.effective_until, v_today - 1), v_today - 1)
                             else v.effective_until end,
      superseded_at = now(), superseded_by = null, updated_by = null
  where v.customer_id = p_customer_id and v.status = 'PUBLISHED'
    and daterange(v.effective_from, coalesce(v.effective_until, 'infinity'::date), '[]')
        && daterange(v_today, 'infinity'::date, '[]');

  update public.customer_schedule_versions v
  set status = 'PUBLISHED', published_at = now(), published_by = null, updated_by = null
  where v.schedule_version_id = v_version_id;

  return v_version_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Importer: one record, or {"records": [...]} up to 60, each in its own
--    subtransaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_schedule_one(
  p_sync_run_id uuid,
  p_record jsonb,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_SCHEDULE';
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_table text := case upper(coalesce(p_record->>'record_type','')) when 'ROUTE' then 'Routes' else 'CustomerSchedule' end;
  v_plan jsonb;
  v_id text;
  v_action text;
  v_target uuid;
  v_version_id uuid;
  v_keys text[];
  v_done integer;
  v_old jsonb;
  v_reason text;
begin
  if v_type not in ('ROUTE','SCHEDULE') then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',p_record->>'source_record_id',
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_SCHEDULE:' || v_type || ':' || lower(coalesce(p_record->>'source_record_id','')), 0));
  v_plan := integration.legacy_sync_plan_schedule_record(p_record);
  v_id := v_plan->>'source_record_id';
  perform integration.legacy_sync_keep_version('CENTRALDB', v_table, v_id, v_plan->>'fingerprint', p_record->'row', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review('CENTRALDB', v_table, v_plan, p_record, p_sync_run_id);
    return v_plan - 'want' - 'merged';
  end if;

  v_action := v_plan->>'action';
  v_target := nullif(v_plan->>'target_id','')::uuid;
  select array_agg(k order by k) into v_keys from jsonb_object_keys(v_plan->'changes') k;

  if v_action in ('CREATE','UPDATE') then
    select count(*) into v_done from public.audit_log a
    where a.correlation_id = p_sync_run_id and a.source_application = c_source;
    if v_done >= p_limit then
      return jsonb_build_object('outcome','RUN_LIMIT_REACHED','record_type',v_type,'source_record_id',v_id,
        'max_entries_per_run',p_limit);
    end if;
  end if;

  if v_type = 'ROUTE' then
    if v_target is not null then
      select to_jsonb(r) into v_old from public.distribution_routes r where r.route_id = v_target;
    end if;
    if v_action = 'CREATE' then
      insert into public.distribution_routes(route_code, display_name, route_color, route_kind, allow_as_default, active,
        sort_order, notes, metadata)
      values (v_id, v_plan->'want'->>'display_name', v_plan->'want'->>'route_color', 'STANDARD', true, true,
        (select coalesce(max(r.sort_order), 0) + 10 from public.distribution_routes r),
        'Created from the legacy CentralDB Routes sheet (legacy sync).',
        jsonb_build_object('source','LEGACY_SYNC','legacy_route_id',v_id))
      returning route_id into v_target;
    elsif v_action = 'UPDATE' then
      update public.distribution_routes r
      set display_name = case when 'display_name' = any(v_keys) then v_plan->'want'->>'display_name' else r.display_name end,
          route_color = case when 'route_color' = any(v_keys) then v_plan->'want'->>'route_color' else r.route_color end
      where r.route_id = v_target;
    end if;
    if v_action in ('CREATE','UPDATE') then
      insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
      values (case v_action when 'CREATE' then 'IMPORT_LEGACY_ROUTE' else 'UPDATE_LEGACY_ROUTE' end,
        'distribution_routes', v_target::text, v_old,
        (select to_jsonb(r) from public.distribution_routes r where r.route_id = v_target),
        'Legacy sync: CentralDB Routes ' || v_id || case when v_action = 'UPDATE' then ' changed ' || array_to_string(v_keys, ', ') else '' end || '.',
        c_source, p_sync_run_id);
    end if;
    if v_action in ('CREATE','ADOPT') then
      insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
        target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
      values ('CENTRALDB', 'Routes', v_id, 'ROUTE_MASTER', 'public.distribution_routes', v_target,
        v_plan->>'fingerprint', p_sync_run_id, jsonb_build_object('action', v_action, 'warnings', v_plan->'warnings'));
    end if;
    insert into integration.legacy_sync_master_states(source_system, source_table, source_record_id, target_table,
      target_id, action, synced, source_fingerprint, sync_run_id)
    values ('CENTRALDB', 'Routes', v_id, 'public.distribution_routes', v_target, v_action, v_plan->'want',
      v_plan->>'fingerprint', p_sync_run_id);

  else
    if v_action in ('CREATE','UPDATE') then
      v_reason := 'Legacy sync: changed in the legacy CentralDB CustomerSchedule ('
        || coalesce((select string_agg(integration.legacy_sync_schedule_key_label(k), ', ' order by k) from unnest(v_keys) k
                     where k !~ '^[1-7]\.' or split_part(k, '.', 1) not in (select x from unnest(v_keys) x where x ~ '^[1-7]$')),
                    'all days') || ').';
      v_version_id := integration.legacy_sync_schedule_publish(v_target, nullif(v_plan->>'current_version_id','')::uuid,
        v_keys, v_plan->'merged', left(v_reason, 500));
      insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
      values ('PUBLISH_CUSTOMER_SCHEDULE', 'customer_schedule_versions', v_version_id::text,
        jsonb_build_object('schedule_version_id', v_plan->>'current_version_id'),
        jsonb_build_object('schedule_version_id', v_version_id, 'customer_id', v_target, 'changes', v_plan->'changes'),
        left(v_reason, 500), c_source, p_sync_run_id);
    end if;
    if v_action in ('CREATE','ADOPT') or (v_action = 'UPDATE' and not exists (
        select 1 from integration.legacy_sync_record_links l
        where l.source_system='CENTRALDB' and l.source_table='CustomerSchedule' and l.source_record_id=v_id
          and l.link_role='CUSTOMER_SCHEDULE' and l.source_line_key='')) then
      insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
        target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
      values ('CENTRALDB', 'CustomerSchedule', v_id, 'CUSTOMER_SCHEDULE', 'public.customers', v_target,
        v_plan->>'fingerprint', p_sync_run_id,
        jsonb_build_object('action', v_action, 'baseline', v_plan->>'baseline', 'warnings', v_plan->'warnings'));
    end if;
    insert into integration.legacy_sync_master_states(source_system, source_table, source_record_id, target_table,
      target_id, action, synced, source_fingerprint, sync_run_id)
    values ('CENTRALDB', 'CustomerSchedule', v_id, 'public.customers', v_target, v_action, v_plan->'want',
      v_plan->>'fingerprint', p_sync_run_id);
  end if;

  return (v_plan - 'want' - 'merged') || jsonb_build_object('outcome',
    case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' when 'RELINK' then 'RELINKED' else 'ADOPTED' end,
    'imported', true, 'target_id', v_target, 'schedule_version_id', v_version_id);
end;
$$;

create or replace function integration.legacy_sync_import_schedule(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_records jsonb;
  v_record jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='SCHEDULE_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy schedule import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  if jsonb_typeof(p_record->'records') = 'array' then
    v_records := p_record->'records';
    if jsonb_array_length(v_records) = 0 or jsonb_array_length(v_records) > 60 then
      raise exception using errcode='22023', message='Send between 1 and 60 legacy schedule or route records.';
    end if;
  else
    v_records := jsonb_build_array(p_record);
  end if;

  for v_record in select value from jsonb_array_elements(v_records) loop
    begin
      v_result := integration.legacy_sync_import_schedule_one(p_sync_run_id, v_record, v_setting.max_entries_per_run);
    exception when others then
      v_result := jsonb_build_object('outcome','ERROR','record_type',upper(coalesce(v_record->>'record_type','')),
        'source_record_id', v_record->>'source_record_id', 'sqlstate', sqlstate, 'error', left(sqlerrm, 300));
    end;
    v_results := v_results || jsonb_build_array(v_result);
    exit when v_result->>'outcome' = 'RUN_LIMIT_REACHED';
  end loop;

  if jsonb_typeof(p_record->'records') <> 'array' or p_record->'records' is null then
    return v_results->0;
  end if;
  return jsonb_build_object('outcome','BATCH','records',jsonb_array_length(v_results),
    'counts', (select coalesce(jsonb_object_agg(o, n), '{}'::jsonb) from (
        select r->>'outcome' as o, count(*) as n from jsonb_array_elements(v_results) r group by 1) x),
    'results', v_results);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Dispatchers: add the kind "schedule".
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_dispatch_dry_run(p_kind text, p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_wash_dry_run(p_records);
    when 'mop' then return integration.legacy_sync_mop_dry_run(p_records);
    when 'trolley' then return integration.legacy_sync_trolley_dry_run(p_records);
    when 'attendance' then return integration.legacy_sync_attendance_dry_run(p_records);
    when 'master' then return integration.legacy_sync_master_dry_run(p_records);
    when 'schedule' then return integration.legacy_sync_schedule_dry_run(p_records);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

create or replace function integration.legacy_sync_dispatch_import(p_kind text, p_sync_run_id uuid, p_record jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_import_wash(p_sync_run_id, p_record);
    when 'mop' then return integration.legacy_sync_import_mop(p_sync_run_id, p_record);
    when 'trolley' then return integration.legacy_sync_import_trolley(p_sync_run_id, p_record);
    when 'attendance' then return integration.legacy_sync_import_attendance(p_sync_run_id, p_record);
    when 'master' then return integration.legacy_sync_import_master(p_sync_run_id, p_record);
    when 'schedule' then return integration.legacy_sync_import_schedule(p_sync_run_id, p_record);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Review page: customers and routes the next run creates are "waiting";
--    an item closes when its record is linked or synced again.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_review_waiting_codes()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array['WASH_NOT_IN_V2','MOP_NOT_IN_V2','FINISH_ENTRY_NOT_IN_V2','TROLLEY_NOT_IN_V2',
               'CUSTOMER_NOT_IN_V2','ROUTE_NOT_IN_V2']::text[];
$$;

create or replace function integration.legacy_sync_review_list()
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='Legacy sync reviews are not available to accounts.';
  end if;

  update integration.legacy_sync_review_items ri
  set status='SUPERSEDED', decided_at=now(), decided_by='Legacy sync',
      decision=jsonb_build_object('action','IMPORTED_LATER')
  where ri.status='OPEN'
    and (exists (select 1 from integration.legacy_sync_record_links l
                 where l.source_system=ri.source_system and l.source_table=ri.source_table
                   and l.source_record_id=ri.source_record_id and l.created_at > ri.created_at)
         or exists (select 1 from integration.legacy_sync_master_states s
                    where s.source_system=ri.source_system and s.source_table=ri.source_table
                      and s.source_record_id=ri.source_record_id and s.created_at > ri.created_at));

  return jsonb_build_object(
    'open', coalesce((
      select jsonb_agg(jsonb_build_object(
          'review_id', ri.review_id, 'source_system', ri.source_system, 'source_table', ri.source_table,
          'source_record_id', ri.source_record_id, 'reason_code', ri.reason_code,
          'detail', ri.raw->>'detail', 'row', ri.raw->'record'->'row', 'created_at', ri.created_at,
          'waiting', ri.reason_code = any(integration.legacy_sync_review_waiting_codes()))
        order by (ri.reason_code = any(integration.legacy_sync_review_waiting_codes())), ri.created_at)
      from integration.legacy_sync_review_items ri where ri.status='OPEN'), '[]'::jsonb),
    'decided', coalesce((
      select jsonb_agg(x order by x->>'decided_at' desc) from (
        select jsonb_build_object(
            'review_id', ri.review_id, 'source_table', ri.source_table, 'source_record_id', ri.source_record_id,
            'reason_code', ri.reason_code, 'detail', ri.raw->>'detail', 'status', ri.status,
            'action', ri.decision->>'action', 'note', ri.decision->>'note',
            'decided_by', ri.decided_by, 'decided_at', ri.decided_at) x
        from integration.legacy_sync_review_items ri
        where ri.status in ('APPROVED','REJECTED') and ri.reason_code <> 'OWNER_TEST_DAY'
        order by ri.decided_at desc limit 30) d), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_weekday(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_key_label(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_trolley_keys(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_want(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_have(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_versions(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_route(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_schedule(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_schedule_record(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_drop_product(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_write_draft(uuid, text[], jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_schedule_publish(uuid, uuid, text[], jsonb, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_schedule_one(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_schedule(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_waiting_codes() from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_list() from public, anon, authenticated;

grant execute on function integration.legacy_sync_schedule_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_schedule(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_review_list() to service_role;

comment on function integration.legacy_sync_plan_schedule(jsonb) is
  'Read-only plan for one legacy customer schedule (all CustomerSchedule rows of a CustomerID): values the legacy app changed since the baseline that V2 does not have.';
comment on function integration.legacy_sync_import_schedule(uuid, jsonb) is
  'Imports legacy routes and customer schedules inside an open COMMIT run, when SCHEDULE_IMPORT is enabled. A schedule change is a new published revision. service_role only.';

commit;
