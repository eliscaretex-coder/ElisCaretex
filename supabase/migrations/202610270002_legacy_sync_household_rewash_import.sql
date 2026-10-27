-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270002_legacy_sync_household_rewash_import
--
-- Owner decisions of 2026-10-27 (Paulo Bressan) for the legacy Finish sync:
--   * legacy HOUSEHOLD Finish entries are ReWash. They are imported into the
--     existing ReWash ledger (finish_rewash_entries / finish_rewash_lines),
--     never into finish_production_entries. ReWash is production, counted
--     separately per table and shift; it is not added to a customer's Clothes
--     flow KG;
--   * every legacy row of Sunday 2026-10-25 is owner test data and is skipped.
--     Other Sundays are real (occasional catch-up) production: imported as
--     usual, with a SUNDAY_PRODUCTION warning.
--
-- Changes:
--   1. legacy_sync_record_links accepts FINISH_ENTRY_TO_REWASH_LINE links.
--   2. New switch FINISH_REWASH_HISTORICAL_IMPORT, seeded OFF, pilot limit 3 cells.
--   3. legacy_sync_plan_finish_entry: 2026-10-25 -> SKIPPED, other Sundays -> warning
--      instead of the SUNDAY_PRODUCTION_REVIEW blocker, HOUSEHOLD -> REWASH_ROUTE.
--      The rest of the body is unchanged from 202610270001.
--   4. legacy_sync_finish_dry_run: also counts SKIPPED and REWASH_ROUTE.
--   5. legacy_sync_plan_household_rewash (read-only) and
--      legacy_sync_import_household_rewash (one Finish cell per call).
--
-- V2 ReWash keeps one ACTIVE entry per business date, shift and table, with
-- one KG line per customer. The importer builds that entry from all the legacy
-- HOUSEHOLD rows of one cell. If the cell already has an ACTIVE ReWash entry
-- (recorded in V2 or imported before) the rows are held for review: nothing
-- is merged into or superseded on an existing entry.
--
-- No trigger change, no change to the live ReWash RPC, no grant to clients.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Links: ReWash line role
-- ---------------------------------------------------------------------
alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check,
  drop constraint legacy_sync_record_links_line_key_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE','FINISH_ENTRY_TO_REWASH_LINE')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='FINISH_ENTRY_TO_REWASH_LINE' and target_table='public.finish_rewash_lines')
  ),
  add constraint legacy_sync_record_links_line_key_check check (
    (link_role in ('FINISH_ENTRY_TO_LINE','FINISH_ENTRY_TO_REWASH_LINE') and length(trim(source_line_key)) > 0)
    or (link_role not in ('FINISH_ENTRY_TO_LINE','FINISH_ENTRY_TO_REWASH_LINE') and source_line_key='')
  );

-- ---------------------------------------------------------------------
-- 2. Switch for the ReWash import (limit = Finish cells per run)
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('FINISH_REWASH_HISTORICAL_IMPORT', false, 3, 'migration 202610270002',
        'Seeded disabled. Legacy HOUSEHOLD rows as ReWash. The limit counts Finish cells (ReWash entries) per run.')
on conflict (setting_key) do nothing;

-- ---------------------------------------------------------------------
-- 3. Planner for NORMAL entries (test day skipped, HOUSEHOLD routed to ReWash)
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_finish_entry(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  c_wash_system constant text := 'CENTRALDB';
  c_wash_table constant text := 'WashItems';
  v_entry jsonb := coalesce(p_record->'entry', 'null'::jsonb);
  v_wash jsonb := coalesce(p_record->'wash_item', 'null'::jsonb);
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_fp text;
  v_wash_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_entry_type text;
  v_status_raw text;
  v_status text;
  v_wash_id text;
  v_type text;
  v_product text;
  v_legacy_customer text;
  v_scheduled date;
  v_business date;
  v_delivery date;
  v_cutoff timestamptz;
  v_recorded_at timestamptz;
  v_shift_code text;
  v_table_code text;
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_candidates uuid[];
  v_approved uuid;
  v_customer public.customers%rowtype;
  v_customer_resolution text;
  v_staff_raw text;
  v_staff public.staff_members%rowtype;
  v_staff_name text;
  v_batch text;
  v_kg numeric;
  v_units numeric;
  v_total numeric;
  v_lines jsonb := '[]'::jsonb;
  v_flow public.production_flow_items%rowtype;
  v_flow_action text;
  v_snapshot record;
  v_schedule jsonb;
  v_trolleys text;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or jsonb_typeof(v_entry) <> 'object' then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','The record must contain an entry object.'));
  end if;

  if v_id is null or length(v_id) > 300 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  elsif integration.legacy_sync_text(v_entry,'EntryID') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH','source_record_id differs from entry.EntryID.');
  end if;

  v_fp := integration.legacy_sync_fingerprint(v_entry);
  v_wash_fp := case when jsonb_typeof(v_wash)='object' then integration.legacy_sync_fingerprint(v_wash) end;

  -- Already imported? Same fingerprint = idempotent retry; different = changed source.
  select * into v_link
  from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role='FINISH_ENTRY_TO_ENTRY';
  if found then
    if v_link.source_fingerprint = v_fp then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','source_record_id',v_id,'fingerprint',v_fp,
        'finish_production_entry_id',v_link.target_id);
    end if;
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,'fingerprint',v_fp,
      'finish_production_entry_id',v_link.target_id,
      'blockers', integration.legacy_sync_issue('SOURCE_CHANGED_AFTER_IMPORT',
        'The legacy entry changed after it was imported. A correction needs an explicit decision.'));
  end if;

  -- Owner decision 2026-10-27: every legacy row of Sunday 2026-10-25 was a test.
  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_entry,'BusinessDate'));
  if v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- Entry type: NORMAL is imported here. HOUSEHOLD is ReWash (owner decision 2026-10-27)
  -- and goes through integration.legacy_sync_import_household_rewash.
  v_entry_type := upper(integration.legacy_sync_text(v_entry,'EntryType'));
  if v_entry_type = 'HOUSEHOLD' then
    return jsonb_build_object('outcome','REWASH_ROUTE','source_record_id',v_id,'fingerprint',v_fp,
      'blockers','[]'::jsonb,'warnings','[]'::jsonb,
      'detail','HOUSEHOLD is imported as ReWash through integration.legacy_sync_import_household_rewash.');
  elsif v_entry_type is distinct from 'NORMAL' then
    v_blockers := v_blockers || integration.legacy_sync_issue('ENTRY_TYPE_NOT_SUPPORTED', v_entry_type);
  end if;

  -- Source status needs an approved map.
  v_status_raw := integration.legacy_sync_text(v_entry,'Status');
  v_status := integration.legacy_sync_map_value(c_system,'FINISH_STATUS',v_status_raw);
  if v_status is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_STATUS_UNMAPPED', v_status_raw);
  elsif v_status <> 'ACTIVE' then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_NOT_ACTIVE', v_status_raw);
  end if;

  -- WashItem: the only source of the scheduled date and product.
  v_wash_id := integration.legacy_sync_text(v_entry,'WashItemID');
  if v_wash_id is null or jsonb_typeof(v_wash) <> 'object' then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_WASH_ITEM');
  else
    if integration.legacy_sync_text(v_wash,'WashItemID') is distinct from v_wash_id then
      v_blockers := v_blockers || integration.legacy_sync_issue('WASH_ITEM_ID_MISMATCH');
    end if;
    v_type := integration.legacy_sync_text(v_wash,'Type');
    v_product := integration.legacy_sync_map_value(c_wash_system,'WASH_ITEM_TYPE',v_type);
    if v_product is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('WASH_ITEM_TYPE_UNMAPPED', v_type);
    elsif v_product <> 'CLOTHES' then
      v_blockers := v_blockers || integration.legacy_sync_issue('PRODUCT_NOT_CLOTHES', v_product);
    end if;
    v_scheduled := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_wash,'ScheduledDate'));
    if v_scheduled is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_SCHEDULED_DATE', integration.legacy_sync_text(v_wash,'ScheduledDate'));
    end if;
    if integration.legacy_sync_text(v_wash,'CustomerID') is distinct from integration.legacy_sync_text(v_entry,'CustomerID') then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_MISMATCH','Finish and WashItem CustomerID differ.');
    end if;
  end if;

  -- Dates.
  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_entry,'BusinessDate'));
  if v_business is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BUSINESS_DATE', integration.legacy_sync_text(v_entry,'BusinessDate'));
  elsif v_business > (now() at time zone 'Europe/Dublin')::date then
    v_blockers := v_blockers || integration.legacy_sync_issue('BUSINESS_DATE_IN_FUTURE', v_business::text);
  elsif extract(isodow from v_business) = 7 then
    -- Sunday production is rare (catch-up or advance work) but real.
    v_warnings := v_warnings || integration.legacy_sync_issue('SUNDAY_PRODUCTION', v_business::text);
  end if;
  if v_scheduled is not null then
    v_delivery := public.next_distribution_business_date(v_scheduled);
    v_cutoff := public.finish_delivery_cutoff(v_delivery);
    if v_business is not null and v_business > v_delivery then
      v_blockers := v_blockers || integration.legacy_sync_issue('BUSINESS_DATE_AFTER_DELIVERY',
        format('Business %s, scheduled %s, delivery %s', v_business, v_scheduled, v_delivery));
    end if;
    if v_business is not null and v_business < v_scheduled then
      v_warnings := v_warnings || integration.legacy_sync_issue('ADVANCE_PRODUCTION',
        format('Finished %s for scheduled %s', v_business, v_scheduled));
    end if;
  end if;

  v_recorded_at := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_entry,'CreatedAt'));
  if v_recorded_at is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_CREATED_AT', integration.legacy_sync_text(v_entry,'CreatedAt'));
  elsif v_recorded_at > now() then
    v_blockers := v_blockers || integration.legacy_sync_issue('CREATED_AT_IN_FUTURE', v_recorded_at::text);
  elsif v_business is not null
        and abs((v_recorded_at at time zone 'Europe/Dublin')::date - v_business) > 1 then
    v_warnings := v_warnings || integration.legacy_sync_issue('CREATED_AT_FAR_FROM_BUSINESS_DATE', v_recorded_at::text);
  end if;

  -- Shift and table.
  v_shift_code := integration.legacy_sync_map_value(c_system,'SHIFT',integration.legacy_sync_text(v_entry,'Shift'));
  if v_shift_code is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_UNMAPPED', integration.legacy_sync_text(v_entry,'Shift'));
  else
    select * into v_shift from public.shifts s
    where s.shift_code=v_shift_code and s.deleted_at is null;
    if not found then
      v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_NOT_FOUND', v_shift_code);
    end if;
  end if;

  v_table_code := integration.legacy_sync_map_value(c_system,'FINISH_TABLE',integration.legacy_sync_text(v_entry,'TableID'));
  if v_table_code is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('TABLE_UNMAPPED', integration.legacy_sync_text(v_entry,'TableID'));
  else
    select st.* into v_station
    from public.stations st
    join public.areas a on a.area_id=st.area_id and a.area_code='FINISH'
    where st.station_code=v_table_code and st.deleted_at is null;
    if not found then
      v_blockers := v_blockers || integration.legacy_sync_issue('TABLE_NOT_FOUND', v_table_code);
    end if;
  end if;

  -- Customer: legacy ID in metadata, then exact code, then an approved CUSTOMER link.
  v_legacy_customer := integration.legacy_sync_text(v_entry,'CustomerID');
  if v_legacy_customer is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_CUSTOMER_ID');
  else
    select array_agg(distinct c.customer_id) into v_candidates
    from public.customers c
    where c.deleted_at is null
      and (c.legacy_metadata->>'legacy_customer_id' = v_legacy_customer
           or c.customer_code = upper(v_legacy_customer));

    select l.target_id into v_approved
    from integration.legacy_sync_record_links l
    where l.source_system=c_wash_system and l.source_table='Customers'
      and l.source_record_id=v_legacy_customer and l.link_role='CUSTOMER';

    if v_approved is not null then
      if v_candidates is null or v_candidates <@ array[v_approved] then
        select * into v_customer from public.customers c where c.customer_id=v_approved and c.deleted_at is null;
        if not found then
          v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_DELETED', v_legacy_customer);
        end if;
        v_customer_resolution := 'APPROVED_LINK';
      else
        v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_CONFLICT',
          'The approved customer link disagrees with the legacy ID or code match.');
      end if;
    elsif coalesce(array_length(v_candidates,1),0) = 1 then
      select * into v_customer from public.customers c where c.customer_id=v_candidates[1];
      v_customer_resolution := case
        when v_customer.legacy_metadata->>'legacy_customer_id' = v_legacy_customer then 'LEGACY_ID'
        else 'CUSTOMER_CODE' end;
    elsif coalesce(array_length(v_candidates,1),0) > 1 then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_AMBIGUOUS', v_legacy_customer);
    elsif exists (select 1 from public.customers c where c.deleted_at is not null
                  and (c.legacy_metadata->>'legacy_customer_id' = v_legacy_customer or c.customer_code = upper(v_legacy_customer))) then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_DELETED', v_legacy_customer);
    else
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_NOT_FOUND', v_legacy_customer);
    end if;

    if v_customer.customer_id is not null and not v_customer.active then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_INACTIVE_PENDING_DECISION', v_customer.customer_code);
    end if;
  end if;

  -- Processing staff: optional in the source. A given ID must map exactly.
  v_staff_raw := integration.legacy_sync_text(v_entry,'StaffUserID');
  v_staff_name := integration.legacy_sync_text(v_entry,'StaffName');
  if v_staff_raw is not null then
    if v_staff_raw !~ '^[0-9]{1,9}$' then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_UNMAPPED', v_staff_raw);
    else
      select * into v_staff from public.staff_members sm
      where sm.legacy_user_id = v_staff_raw::integer and sm.deleted_at is null;
      if not found then
        v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_UNMAPPED', v_staff_raw);
      end if;
    end if;
  else
    v_warnings := v_warnings || integration.legacy_sync_issue('PROCESSED_BY_NOT_IN_SOURCE');
  end if;

  -- Lines: KG and UNIT are separate lines. TotalKg is a check only.
  v_batch := upper(integration.legacy_sync_text(v_entry,'BatchNo'));
  if v_batch is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_BATCH_REFERENCE');
  elsif length(v_batch) > 120 then
    v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_TOO_LONG');
  end if;

  if integration.legacy_sync_text(v_entry,'QtyKg') is not null then
    v_kg := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'QtyKg'));
    if v_kg is null or v_kg < 0 then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyKg='||integration.legacy_sync_text(v_entry,'QtyKg'));
      v_kg := null;
    elsif v_kg <> round(v_kg,2) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyKg has more than 2 decimals: '||v_kg::text);
    end if;
  end if;
  if integration.legacy_sync_text(v_entry,'QtyUnits') is not null then
    v_units := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'QtyUnits'));
    if v_units is null or v_units < 0 then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyUnits='||integration.legacy_sync_text(v_entry,'QtyUnits'));
      v_units := null;
    elsif v_units <> trunc(v_units) then
      v_blockers := v_blockers || integration.legacy_sync_issue('FRACTIONAL_UNITS', v_units::text);
    end if;
  end if;
  if integration.legacy_sync_text(v_entry,'TotalKg') is not null then
    v_total := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'TotalKg'));
    if v_total is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'TotalKg='||integration.legacy_sync_text(v_entry,'TotalKg'));
    elsif abs(v_total - coalesce(v_kg,0)) > 0.005 then
      v_blockers := v_blockers || integration.legacy_sync_issue('TOTAL_KG_MISMATCH',
        format('TotalKg %s, QtyKg %s', v_total, coalesce(v_kg,0)));
    end if;
  end if;
  if coalesce(v_kg,0) = 0 and coalesce(v_units,0) = 0 then
    v_blockers := v_blockers || integration.legacy_sync_issue('NO_QUANTITY');
  end if;
  if coalesce(v_kg,0) > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_no', jsonb_array_length(v_lines)+1, 'batch_reference', v_batch, 'unit_code', 'KG', 'quantity', v_kg));
  end if;
  if coalesce(v_units,0) > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_no', jsonb_array_length(v_lines)+1, 'batch_reference', v_batch, 'unit_code', 'UNIT', 'quantity', v_units));
  end if;
  select coalesce(jsonb_agg(l || jsonb_build_object('source_line_key', (l->>'unit_code')||':'||(l->>'line_no'))
                            order by (l->>'line_no')::integer), '[]'::jsonb)
  into v_lines from jsonb_array_elements(v_lines) l;

  -- Flow by canonical key. Never by flow_code, never one flow per WashItem.
  if v_customer.customer_id is not null and v_scheduled is not null and v_product = 'CLOTHES' then
    select * into v_flow from public.production_flow_items f
    where f.customer_id=v_customer.customer_id and f.product_code='CLOTHES' and f.scheduled_for_date=v_scheduled;
    if found then
      v_flow_action := 'EXISTING';
      if v_flow.flow_status = 'CANCELLED' then
        v_blockers := v_blockers || integration.legacy_sync_issue('FLOW_CANCELLED', v_flow.flow_code);
      end if;
    else
      v_flow_action := 'CREATE';
      begin
        select * into v_snapshot from public.sorting_schedule_product_snapshot(v_customer.customer_id,'CLOTHES',v_scheduled);
        v_schedule := jsonb_build_object(
          'schedule_version_id', v_snapshot.schedule_version_id, 'schedule_day_id', v_snapshot.schedule_day_id,
          'schedule_product_id', v_snapshot.schedule_product_id, 'production_order', v_snapshot.production_order,
          'route_id', v_snapshot.route_id, 'route_code', v_snapshot.route_code,
          'route_display_name', v_snapshot.route_display_name, 'route_color', v_snapshot.route_color);
      exception when others then
        v_blockers := v_blockers || integration.legacy_sync_issue('SCHEDULE_NOT_PUBLISHED',
          format('No published CLOTHES schedule for %s on %s.', v_customer.customer_code, v_scheduled));
      end;
    end if;

    -- The same WashItem must not already point at another flow.
    if exists (select 1 from integration.legacy_sync_record_links l
               where l.source_system=c_wash_system and l.source_table=c_wash_table
                 and l.source_record_id=v_wash_id and l.link_role='WASH_ITEM_TO_FLOW'
                 and (v_flow.production_flow_item_id is null or l.target_id <> v_flow.production_flow_item_id)) then
      v_blockers := v_blockers || integration.legacy_sync_issue('WASH_ITEM_LINKED_TO_OTHER_FLOW', v_wash_id);
    end if;

    if v_flow.production_flow_item_id is not null and v_business is not null
       and v_shift_code is not null and v_table_code is not null then
      if exists (select 1 from public.finish_production_entries e
                 where e.production_flow_item_id=v_flow.production_flow_item_id and e.status='ACTIVE'
                   and e.production_business_date=v_business and e.shift_code_snapshot=v_shift_code
                   and e.table_code_snapshot=v_table_code) then
        v_blockers := v_blockers || integration.legacy_sync_issue('CELL_HAS_ACTIVE_ENTRY',
          'The flow already has an ACTIVE Finish entry for this date, shift and table.');
      end if;
    end if;
  end if;

  -- Batch reference must be free on the business date and on the flow.
  if v_batch is not null and v_business is not null and exists (
       select 1 from public.finish_production_entries e
       join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
       where e.status='ACTIVE' and lower(l.batch_reference)=lower(v_batch)
         and (e.production_business_date=v_business
              or (v_flow.production_flow_item_id is not null and e.production_flow_item_id=v_flow.production_flow_item_id))) then
    v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_IN_USE', v_batch);
  end if;

  v_trolleys := integration.legacy_sync_text(v_entry,'Trolleys');

  return jsonb_build_object(
    'outcome', case when jsonb_array_length(v_blockers)=0 then 'READY' else 'BLOCKED' end,
    'source_record_id', v_id,
    'fingerprint', v_fp,
    'wash_item_fingerprint', v_wash_fp,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'resolved', jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_resolution', v_customer_resolution,
      'wash_item_id', v_wash_id,
      'product_code', v_product,
      'scheduled_for_date', v_scheduled,
      'production_business_date', v_business,
      'delivery_date', v_delivery,
      'edit_cutoff_at', v_cutoff,
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift_code,
      'station_id', v_station.station_id,
      'table_code', v_table_code,
      'table_name', v_station.station_name,
      'recorded_at', v_recorded_at,
      'processed_by_staff_id', v_staff.staff_id,
      'processed_by_name', coalesce(v_staff.display_name, v_staff_name),
      'flow_action', v_flow_action,
      'production_flow_item_id', v_flow.production_flow_item_id,
      'flow_code', v_flow.flow_code,
      'schedule', v_schedule,
      'trolley_codes_raw', v_trolleys),
    'lines', v_lines,
    'totals', jsonb_build_object('kg', coalesce(v_kg,0), 'units', coalesce(v_units,0)));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run for NORMAL entries: also counts SKIPPED and REWASH_ROUTE
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_finish_dry_run(p_records jsonb)
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
  v_extra jsonb;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array'
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 60 then
    raise exception using errcode='22023', message='Send between 1 and 60 legacy Finish records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_finish_entry(v_record));
  end loop;

  -- Batch-level checks: the same legacy entry twice, two entries in one
  -- Finish cell (owner decision), the same batch reference twice in a day.
  for v_plan in select value from jsonb_array_elements(v_plans) loop
    v_extra := '[]'::jsonb;
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id') > 1 then
      v_extra := v_extra || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH');
    end if;
    if v_plan#>>'{resolved,customer_id}' is not null and (
        select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' is distinct from v_plan->>'source_record_id'
          and o#>>'{resolved,customer_id}' = v_plan#>>'{resolved,customer_id}'
          and o#>>'{resolved,scheduled_for_date}' = v_plan#>>'{resolved,scheduled_for_date}'
          and o#>>'{resolved,production_business_date}' = v_plan#>>'{resolved,production_business_date}'
          and o#>>'{resolved,shift_code}' = v_plan#>>'{resolved,shift_code}'
          and o#>>'{resolved,table_code}' = v_plan#>>'{resolved,table_code}') > 0 then
      v_extra := v_extra || integration.legacy_sync_issue('CELL_SHARED_IN_BATCH',
        'Another legacy entry targets the same flow, date, shift and table. Needs an owner decision.');
    end if;
    if v_plan#>>'{lines,0,batch_reference}' is not null and (
        select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' is distinct from v_plan->>'source_record_id'
          and lower(o#>>'{lines,0,batch_reference}') = lower(v_plan#>>'{lines,0,batch_reference}')
          and o#>>'{resolved,production_business_date}' = v_plan#>>'{resolved,production_business_date}') > 0 then
      v_extra := v_extra || integration.legacy_sync_issue('BATCH_REFERENCE_DUPLICATE_IN_BATCH', v_plan#>>'{lines,0,batch_reference}');
    end if;
    if jsonb_array_length(v_extra) > 0 and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','blockers', coalesce(v_plan->'blockers','[]'::jsonb) || v_extra);
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
  end loop;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'skipped', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='SKIPPED'),
    'rewash_route', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='REWASH_ROUTE'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'ready_kg', (select coalesce(sum((o#>>'{totals,kg}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'ready_units', (select coalesce(sum((o#>>'{totals,units}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Customer resolution shared by the ReWash planner. Same order as the
--    NORMAL planner: legacy ID in metadata, exact code, approved link.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_resolve_customer(p_legacy_customer text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_candidates uuid[];
  v_approved uuid;
  v_customer public.customers%rowtype;
  v_resolution text;
  v_blockers jsonb := '[]'::jsonb;
begin
  if p_legacy_customer is null then
    return jsonb_build_object('blockers', integration.legacy_sync_issue('MISSING_CUSTOMER_ID'));
  end if;

  select array_agg(distinct c.customer_id) into v_candidates
  from public.customers c
  where c.deleted_at is null
    and (c.legacy_metadata->>'legacy_customer_id' = p_legacy_customer
         or c.customer_code = upper(p_legacy_customer));

  select l.target_id into v_approved
  from integration.legacy_sync_record_links l
  where l.source_system='CENTRALDB' and l.source_table='Customers'
    and l.source_record_id=p_legacy_customer and l.link_role='CUSTOMER';

  if v_approved is not null then
    if v_candidates is null or v_candidates <@ array[v_approved] then
      select * into v_customer from public.customers c where c.customer_id=v_approved and c.deleted_at is null;
      if not found then
        v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_DELETED', p_legacy_customer);
      end if;
      v_resolution := 'APPROVED_LINK';
    else
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_CONFLICT',
        'The approved customer link disagrees with the legacy ID or code match.');
    end if;
  elsif coalesce(array_length(v_candidates,1),0) = 1 then
    select * into v_customer from public.customers c where c.customer_id=v_candidates[1];
    v_resolution := case
      when v_customer.legacy_metadata->>'legacy_customer_id' = p_legacy_customer then 'LEGACY_ID'
      else 'CUSTOMER_CODE' end;
  elsif coalesce(array_length(v_candidates,1),0) > 1 then
    v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_AMBIGUOUS', p_legacy_customer);
  elsif exists (select 1 from public.customers c where c.deleted_at is not null
                and (c.legacy_metadata->>'legacy_customer_id' = p_legacy_customer or c.customer_code = upper(p_legacy_customer))) then
    v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_DELETED', p_legacy_customer);
  else
    v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_NOT_FOUND', p_legacy_customer);
  end if;

  return jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_active', v_customer.active,
    'resolution', v_resolution,
    'blockers', v_blockers);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. ReWash planner: 1-60 legacy HOUSEHOLD rows. Read-only (STABLE).
--
-- Record shape is the same as for NORMAL entries ({source_record_id,
-- entry, wash_item}); wash_item is ignored. Returns one plan per record and
-- one cell per (business date, shift, table) whose rows are all READY.
-- A cell is all-or-nothing: one blocked row holds the whole cell.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_household_rewash(p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  v_rec jsonb;
  v_entry jsonb;
  v_id text;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_status_raw text;
  v_status text;
  v_business date;
  v_recorded_at timestamptz;
  v_shift_code text;
  v_table_code text;
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_cust jsonb;
  v_customer public.customers%rowtype;
  v_option jsonb;
  v_staff_raw text;
  v_staff public.staff_members%rowtype;
  v_batch text;
  v_kg numeric;
  v_units numeric;
  v_total numeric;
  v_plans jsonb := '[]'::jsonb;
  v_plan jsonb;
  v_out jsonb := '[]'::jsonb;
  v_extra jsonb;
  v_cells jsonb;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array'
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 60 then
    raise exception using errcode='22023', message='Send between 1 and 60 legacy HOUSEHOLD records.';
  end if;

  for v_rec in select value from jsonb_array_elements(p_records) loop
    v_entry := coalesce(v_rec->'entry', 'null'::jsonb);
    v_id := integration.legacy_sync_text(v_rec, 'source_record_id');
    v_blockers := '[]'::jsonb;
    v_warnings := '[]'::jsonb;
    v_business := null; v_recorded_at := null; v_shift_code := null; v_table_code := null;
    v_shift := null; v_station := null; v_customer := null; v_option := null; v_staff := null;
    v_batch := null; v_kg := null; v_units := null; v_total := null; v_status := null;

    if jsonb_typeof(v_rec) <> 'object' or jsonb_typeof(v_entry) <> 'object' then
      v_plans := v_plans || jsonb_build_array(jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
        'blockers', integration.legacy_sync_issue('INVALID_RECORD','The record must contain an entry object.')));
      continue;
    end if;

    if v_id is null or length(v_id) > 300 then
      v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
    elsif integration.legacy_sync_text(v_entry,'EntryID') is distinct from v_id then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH','source_record_id differs from entry.EntryID.');
    end if;

    v_fp := integration.legacy_sync_fingerprint(v_entry);

    -- Already imported as ReWash? Same fingerprint = idempotent retry.
    select * into v_link
    from integration.legacy_sync_record_links l
    where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
      and l.link_role in ('FINISH_ENTRY_TO_REWASH_LINE','FINISH_ENTRY_TO_ENTRY')
    order by l.created_at
    limit 1;
    if found then
      if v_link.link_role = 'FINISH_ENTRY_TO_ENTRY' then
        v_plans := v_plans || jsonb_build_array(jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
          'fingerprint',v_fp,'blockers', integration.legacy_sync_issue('IMPORTED_AS_NORMAL_ENTRY',
            'This legacy entry was already imported as a Finish production entry.')));
      elsif v_link.source_fingerprint = v_fp then
        v_plans := v_plans || jsonb_build_array(jsonb_build_object('outcome','ALREADY_IMPORTED','source_record_id',v_id,
          'fingerprint',v_fp,'finish_rewash_line_id',v_link.target_id,
          'finish_rewash_entry_id',v_link.link_metadata->>'finish_rewash_entry_id'));
      else
        v_plans := v_plans || jsonb_build_array(jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
          'fingerprint',v_fp,'finish_rewash_line_id',v_link.target_id,
          'blockers', integration.legacy_sync_issue('SOURCE_CHANGED_AFTER_IMPORT',
            'The legacy entry changed after it was imported. A correction needs an explicit decision.')));
      end if;
      continue;
    end if;

    -- Owner decision 2026-10-27: every legacy row of Sunday 2026-10-25 was a test.
    v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_entry,'BusinessDate'));
    if v_business = date '2026-10-25' then
      v_plans := v_plans || jsonb_build_array(jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,
        'fingerprint',v_fp,'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb));
      continue;
    end if;

    if upper(integration.legacy_sync_text(v_entry,'EntryType')) is distinct from 'HOUSEHOLD' then
      v_blockers := v_blockers || integration.legacy_sync_issue('ENTRY_TYPE_NOT_HOUSEHOLD',
        integration.legacy_sync_text(v_entry,'EntryType'));
    end if;

    v_status_raw := integration.legacy_sync_text(v_entry,'Status');
    v_status := integration.legacy_sync_map_value(c_system,'FINISH_STATUS',v_status_raw);
    if v_status is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_STATUS_UNMAPPED', v_status_raw);
    elsif v_status <> 'ACTIVE' then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_NOT_ACTIVE', v_status_raw);
    end if;

    if integration.legacy_sync_text(v_entry,'WashItemID') is not null then
      v_warnings := v_warnings || integration.legacy_sync_issue('HOUSEHOLD_WASH_ITEM_IGNORED',
        integration.legacy_sync_text(v_entry,'WashItemID'));
    end if;

    if v_business is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BUSINESS_DATE', integration.legacy_sync_text(v_entry,'BusinessDate'));
    elsif v_business > (now() at time zone 'Europe/Dublin')::date then
      v_blockers := v_blockers || integration.legacy_sync_issue('BUSINESS_DATE_IN_FUTURE', v_business::text);
    elsif extract(isodow from v_business) = 7 then
      v_warnings := v_warnings || integration.legacy_sync_issue('SUNDAY_PRODUCTION', v_business::text);
    end if;

    v_recorded_at := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_entry,'CreatedAt'));
    if v_recorded_at is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_CREATED_AT', integration.legacy_sync_text(v_entry,'CreatedAt'));
    elsif v_recorded_at > now() then
      v_blockers := v_blockers || integration.legacy_sync_issue('CREATED_AT_IN_FUTURE', v_recorded_at::text);
    elsif v_business is not null
          and abs((v_recorded_at at time zone 'Europe/Dublin')::date - v_business) > 1 then
      v_warnings := v_warnings || integration.legacy_sync_issue('CREATED_AT_FAR_FROM_BUSINESS_DATE', v_recorded_at::text);
    end if;

    v_shift_code := integration.legacy_sync_map_value(c_system,'SHIFT',integration.legacy_sync_text(v_entry,'Shift'));
    if v_shift_code is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_UNMAPPED', integration.legacy_sync_text(v_entry,'Shift'));
    else
      select * into v_shift from public.shifts s where s.shift_code=v_shift_code and s.deleted_at is null;
      if not found then
        v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_NOT_FOUND', v_shift_code);
      end if;
    end if;

    v_table_code := integration.legacy_sync_map_value(c_system,'FINISH_TABLE',integration.legacy_sync_text(v_entry,'TableID'));
    if v_table_code is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('TABLE_UNMAPPED', integration.legacy_sync_text(v_entry,'TableID'));
    else
      select st.* into v_station
      from public.stations st
      join public.areas a on a.area_id=st.area_id and a.area_code='FINISH'
      where st.station_code=v_table_code and st.deleted_at is null;
      if not found then
        v_blockers := v_blockers || integration.legacy_sync_issue('TABLE_NOT_FOUND', v_table_code);
      end if;
    end if;

    -- Customer, and ReWash eligibility exactly as record_finish_rewash_v1 checks it.
    v_cust := integration.legacy_sync_resolve_customer(integration.legacy_sync_text(v_entry,'CustomerID'));
    v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
    if v_cust->>'customer_id' is not null then
      select * into v_customer from public.customers c where c.customer_id=(v_cust->>'customer_id')::uuid;
      if v_business is not null then
        select opt into v_option
        from jsonb_array_elements(public.finish_rewash_customer_options_v1(v_business)) opt
        where opt->>'customer_id' = v_customer.customer_id::text
        limit 1;
        if v_option is null then
          v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_CUSTOMER_NOT_ELIGIBLE',
            format('%s is not an active customer with a published CLOTHES/OTHERS schedule on %s.', v_customer.customer_code, v_business));
        end if;
      end if;
    end if;

    v_staff_raw := integration.legacy_sync_text(v_entry,'StaffUserID');
    if v_staff_raw is not null then
      if v_staff_raw !~ '^[0-9]{1,9}$' then
        v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_UNMAPPED', v_staff_raw);
      else
        select * into v_staff from public.staff_members sm
        where sm.legacy_user_id = v_staff_raw::integer and sm.deleted_at is null;
        if not found then
          v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_UNMAPPED', v_staff_raw);
        end if;
      end if;
    else
      v_warnings := v_warnings || integration.legacy_sync_issue('PROCESSED_BY_NOT_IN_SOURCE');
    end if;

    -- ReWash is KG only. Batch reference is optional, as in V2.
    v_batch := upper(integration.legacy_sync_text(v_entry,'BatchNo'));
    if v_batch is not null and length(v_batch) > 120 then
      v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_TOO_LONG');
    end if;
    if integration.legacy_sync_text(v_entry,'QtyKg') is not null then
      v_kg := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'QtyKg'));
      if v_kg is null or v_kg < 0 or v_kg > 10000 then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyKg='||integration.legacy_sync_text(v_entry,'QtyKg'));
        v_kg := null;
      elsif v_kg <> round(v_kg,2) then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyKg has more than 2 decimals: '||v_kg::text);
      end if;
    end if;
    if coalesce(v_kg,0) = 0 then
      v_blockers := v_blockers || integration.legacy_sync_issue('NO_QUANTITY');
    end if;
    if integration.legacy_sync_text(v_entry,'QtyUnits') is not null then
      v_units := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'QtyUnits'));
      if v_units is null then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'QtyUnits='||integration.legacy_sync_text(v_entry,'QtyUnits'));
      elsif v_units <> 0 then
        v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_UNITS_NOT_SUPPORTED', v_units::text);
      end if;
    end if;
    if integration.legacy_sync_text(v_entry,'TotalKg') is not null then
      v_total := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'TotalKg'));
      if v_total is null then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', 'TotalKg='||integration.legacy_sync_text(v_entry,'TotalKg'));
      elsif abs(v_total - coalesce(v_kg,0)) > 0.005 then
        v_blockers := v_blockers || integration.legacy_sync_issue('TOTAL_KG_MISMATCH',
          format('TotalKg %s, QtyKg %s', v_total, coalesce(v_kg,0)));
      end if;
    end if;

    -- Same batch rule as record_finish_rewash_v1: free among ACTIVE Finish and ReWash records of the day.
    if v_batch is not null and v_business is not null and exists (
         select 1 from public.finish_production_entries e
         join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
         where e.status='ACTIVE' and e.production_business_date=v_business and lower(l.batch_reference)=lower(v_batch)
         union all
         select 1 from public.finish_rewash_entries e
         join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
         where e.status='ACTIVE' and e.production_business_date=v_business and lower(coalesce(l.batch_reference,''))=lower(v_batch)) then
      v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_IN_USE', v_batch);
    end if;

    -- One ACTIVE ReWash entry per cell. Never merge into or supersede it.
    if v_business is not null and v_shift_code is not null and v_table_code is not null and exists (
         select 1 from public.finish_rewash_entries e
         where e.status='ACTIVE' and e.production_business_date=v_business
           and e.shift_code_snapshot=v_shift_code and e.table_code_snapshot=v_table_code) then
      v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_CELL_HAS_ACTIVE_ENTRY',
        format('%s %s %s already has an ACTIVE ReWash entry.', v_business, v_shift_code, v_table_code));
    end if;

    v_plans := v_plans || jsonb_build_array(jsonb_build_object(
      'outcome', case when jsonb_array_length(v_blockers)=0 then 'READY' else 'BLOCKED' end,
      'source_record_id', v_id,
      'fingerprint', v_fp,
      'blockers', v_blockers,
      'warnings', v_warnings,
      'resolved', jsonb_build_object(
        'cell_key', case when v_business is not null and v_shift_code is not null and v_table_code is not null
                         then v_business::text||'|'||v_shift_code||'|'||v_table_code end,
        'production_business_date', v_business,
        'shift_id', v_shift.shift_id,
        'shift_code', v_shift_code,
        'station_id', v_station.station_id,
        'table_code', v_table_code,
        'table_name', v_station.station_name,
        'recorded_at', v_recorded_at,
        'customer_id', v_customer.customer_id,
        'customer_code', coalesce(v_option->>'customer_code', v_customer.customer_code),
        'customer_name', coalesce(v_option->>'customer_name', v_customer.customer_name),
        'customer_resolution', v_cust->>'resolution',
        'service_codes', coalesce(v_option->'service_codes','[]'::jsonb),
        'scheduled_days', coalesce(v_option->'scheduled_days','[]'::jsonb),
        'processed_by_staff_id', v_staff.staff_id,
        'processed_by_name', coalesce(v_staff.display_name, integration.legacy_sync_text(v_entry,'StaffName')),
        'batch_reference', v_batch,
        'quantity_kg', v_kg,
        'notes', integration.legacy_sync_text(v_entry,'Notes'))));
  end loop;

  -- Batch checks, then all-or-nothing per cell.
  for v_plan in select value from jsonb_array_elements(v_plans) loop
    v_extra := '[]'::jsonb;
    if v_plan->>'outcome' in ('READY','BLOCKED') then
      if (select count(*) from jsonb_array_elements(v_plans) o
          where o->>'source_record_id' = v_plan->>'source_record_id') > 1 then
        v_extra := v_extra || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH');
      end if;
      if v_plan#>>'{resolved,batch_reference}' is not null and (
          select count(*) from jsonb_array_elements(v_plans) o
          where o->>'source_record_id' is distinct from v_plan->>'source_record_id'
            and o->>'outcome' in ('READY','BLOCKED')
            and lower(o#>>'{resolved,batch_reference}') = lower(v_plan#>>'{resolved,batch_reference}')
            and o#>>'{resolved,production_business_date}' = v_plan#>>'{resolved,production_business_date}') > 0 then
        v_extra := v_extra || integration.legacy_sync_issue('BATCH_REFERENCE_DUPLICATE_IN_BATCH', v_plan#>>'{resolved,batch_reference}');
      end if;
    end if;
    if jsonb_array_length(v_extra) > 0 then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','blockers', coalesce(v_plan->'blockers','[]'::jsonb) || v_extra);
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
  end loop;

  v_plans := v_out;
  v_out := '[]'::jsonb;
  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if v_plan->>'outcome' = 'READY' and exists (
         select 1 from jsonb_array_elements(v_plans) o
         where o->>'outcome' = 'BLOCKED' and o#>>'{resolved,cell_key}' = v_plan#>>'{resolved,cell_key}') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','blockers',
        coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('CELL_HAS_BLOCKED_RECORD',
          'Another legacy HOUSEHOLD row of this Finish cell is blocked. The cell is imported as a whole.'));
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
  end loop;

  -- READY cells: one future ReWash entry each, one KG line per legacy row.
  select coalesce(jsonb_agg(cell order by cell->>'cell_key'), '[]'::jsonb) into v_cells
  from (
    select jsonb_build_object(
      'cell_key', k,
      'production_business_date', min(o#>>'{resolved,production_business_date}'),
      'shift_id', min(o#>>'{resolved,shift_id}'),
      'shift_code', min(o#>>'{resolved,shift_code}'),
      'station_id', min(o#>>'{resolved,station_id}'),
      'table_code', min(o#>>'{resolved,table_code}'),
      'table_name', min(o#>>'{resolved,table_name}'),
      'recorded_at', max((o#>>'{resolved,recorded_at}')::timestamptz),
      'processed_by_staff_id', case
        when count(*) = count(o#>>'{resolved,processed_by_staff_id}')
         and count(distinct o#>>'{resolved,processed_by_staff_id}') = 1
        then min(o#>>'{resolved,processed_by_staff_id}') end,
      'processed_by_name', case
        when count(*) = count(o#>>'{resolved,processed_by_name}')
         and count(distinct o#>>'{resolved,processed_by_name}') = 1
        then min(o#>>'{resolved,processed_by_name}')
        else 'Legacy Finish (Apps Script)' end,
      'notes', string_agg(o#>>'{resolved,notes}', ' | ' order by (o#>>'{resolved,recorded_at}')::timestamptz, o->>'source_record_id'),
      'records', count(*),
      'total_kg', sum((o#>>'{resolved,quantity_kg}')::numeric),
      'lines', jsonb_agg(jsonb_build_object(
          'source_record_id', o->>'source_record_id',
          'fingerprint', o->>'fingerprint',
          'customer_id', o#>>'{resolved,customer_id}',
          'customer_code', o#>>'{resolved,customer_code}',
          'customer_name', o#>>'{resolved,customer_name}',
          'service_codes', o#>'{resolved,service_codes}',
          'scheduled_days', o#>'{resolved,scheduled_days}',
          'batch_reference', o#>>'{resolved,batch_reference}',
          'quantity_kg', (o#>>'{resolved,quantity_kg}')::numeric,
          'warnings', o->'warnings')
        order by (o#>>'{resolved,recorded_at}')::timestamptz, o->>'source_record_id')) as cell
    from jsonb_array_elements(v_out) o, lateral (select o#>>'{resolved,cell_key}' as k) x
    where o->>'outcome' = 'READY'
    group by k
  ) c;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'skipped', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='SKIPPED'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'ready_cells', jsonb_array_length(v_cells),
    'ready_kg', (select coalesce(sum((o#>>'{resolved,quantity_kg}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'cells', v_cells,
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. ReWash importer: the legacy HOUSEHOLD rows of ONE Finish cell per call,
--    one transaction. Rows of the 2026-10-25 test day are recorded as skipped.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_household_rewash(
  p_sync_run_id uuid,
  p_records jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  c_source constant text := 'LEGACY_SYNC_FINISH';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_result jsonb;
  v_cell_keys text[];
  v_cell jsonb;
  v_item record;
  v_blocker jsonb;
  v_done integer;
  v_entry public.finish_rewash_entries%rowtype;
  v_line jsonb;
  v_line_no integer := 0;
  v_line_id uuid;
  v_lines jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='FINISH_REWASH_HISTORICAL_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy HOUSEHOLD ReWash import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  -- First plan only to find the cell, then lock it and plan again.
  v_result := integration.legacy_sync_plan_household_rewash(p_records);
  select array_agg(distinct o#>>'{resolved,cell_key}') into v_cell_keys
  from jsonb_array_elements(v_result->'plans') o
  where o#>>'{resolved,cell_key}' is not null;
  if coalesce(array_length(v_cell_keys,1),0) > 1 then
    raise exception using errcode='22023', message='Send the legacy HOUSEHOLD rows of one Finish cell (date, shift, table) per call.';
  end if;
  if v_cell_keys is not null then
    perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_REWASH_CELL:'||v_cell_keys[1], 0));
    v_result := integration.legacy_sync_plan_household_rewash(p_records);
  end if;

  if jsonb_array_length(v_result->'cells') > 0 then
    select count(distinct l.link_metadata->>'finish_rewash_entry_id') into v_done
    from integration.legacy_sync_record_links l
    where l.sync_run_id=p_sync_run_id and l.link_role='FINISH_ENTRY_TO_REWASH_LINE';
    if v_done >= v_setting.max_entries_per_run then
      return jsonb_build_object('outcome','RUN_LIMIT_REACHED','max_entries_per_run',v_setting.max_entries_per_run);
    end if;
  end if;

  -- Keep every distinct source version; skipped and blocked rows are recorded too.
  for v_item in
    select p.value as plan, r.value as rec
    from jsonb_array_elements(v_result->'plans') with ordinality p(value, n)
    join jsonb_array_elements(p_records) with ordinality r(value, n) using (n)
  loop
    if v_item.plan->>'fingerprint' is not null and v_item.plan->>'source_record_id' is not null then
      insert into integration.legacy_sync_record_versions(source_system, source_table, source_record_id,
        source_fingerprint, payload, first_seen_run)
      values (c_system, c_table, v_item.plan->>'source_record_id', v_item.plan->>'fingerprint',
        v_item.rec->'entry', p_sync_run_id)
      on conflict on constraint legacy_sync_record_versions_uq do nothing;
    end if;

    if v_item.plan->>'outcome' = 'SKIPPED' and not exists (
         select 1 from integration.legacy_sync_review_items ri
         where ri.source_system=c_system and ri.source_table=c_table
           and ri.source_record_id=v_item.plan->>'source_record_id' and ri.reason_code=v_item.plan->>'skip_reason') then
      insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id, reason_code,
        raw, status, decision, decided_by, decided_at, sync_run_id)
      values (c_system, c_table, v_item.plan->>'source_record_id', v_item.plan->>'skip_reason',
        jsonb_build_object('record', v_item.rec, 'fingerprint', v_item.plan->>'fingerprint'),
        'REJECTED', jsonb_build_object('action','NOT_IMPORTED','rule','All legacy rows of Sunday 2026-10-25 were owner tests.'),
        'Owner decision 2026-10-27', now(), p_sync_run_id);
    elsif v_item.plan->>'outcome' = 'BLOCKED' and v_item.plan->>'source_record_id' is not null then
      for v_blocker in select value from jsonb_array_elements(coalesce(v_item.plan->'blockers','[]'::jsonb)) loop
        insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id,
          reason_code, raw, sync_run_id)
        values (c_system, c_table, v_item.plan->>'source_record_id', v_blocker->>'code',
          jsonb_build_object('record', v_item.rec, 'detail', v_blocker->>'detail', 'fingerprint', v_item.plan->>'fingerprint'),
          p_sync_run_id)
        on conflict (source_system, source_table, source_record_id, reason_code) where status='OPEN' do nothing;
      end loop;
    end if;
  end loop;

  if jsonb_array_length(v_result->'cells') = 0 then
    return v_result - 'mode' - 'writes_performed' || jsonb_build_object('outcome','NOTHING_IMPORTED');
  end if;

  v_cell := v_result->'cells'->0;

  -- The partial unique index finish_rewash_one_active_cell_uq still guards a
  -- concurrent V2 save of the same cell: this insert then fails and rolls back.
  insert into public.finish_rewash_entries(
    finish_rewash_entry_id, entry_group_id, revision_no, status, supersedes_finish_rewash_entry_id,
    production_business_date, shift_id, shift_code_snapshot, station_id, table_code_snapshot, table_name_snapshot,
    processed_by_staff_id, processed_by_name_snapshot, notes, recorded_at, recorded_by_staff_id, recorded_by_auth_user_id)
  select g, g, 1, 'ACTIVE', null,
    (v_cell->>'production_business_date')::date, (v_cell->>'shift_id')::uuid, v_cell->>'shift_code',
    (v_cell->>'station_id')::uuid, v_cell->>'table_code', v_cell->>'table_name',
    nullif(v_cell->>'processed_by_staff_id','')::uuid, v_cell->>'processed_by_name',
    left(v_cell->>'notes', 2000), (v_cell->>'recorded_at')::timestamptz, null, null
  from (select gen_random_uuid() as g) x
  returning * into v_entry;

  for v_line in select value from jsonb_array_elements(v_cell->'lines') loop
    v_line_no := v_line_no + 1;
    insert into public.finish_rewash_lines(finish_rewash_entry_id, line_no, customer_id, customer_code_snapshot,
      customer_name_snapshot, service_codes_snapshot, scheduled_days_snapshot, batch_reference, quantity_kg)
    values (v_entry.finish_rewash_entry_id, v_line_no, (v_line->>'customer_id')::uuid, v_line->>'customer_code',
      v_line->>'customer_name',
      array(select jsonb_array_elements_text(coalesce(v_line->'service_codes','[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(v_line->'scheduled_days','[]'::jsonb))),
      v_line->>'batch_reference', (v_line->>'quantity_kg')::numeric)
    returning finish_rewash_line_id into v_line_id;

    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id,
      source_line_key, link_role, target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_line->>'source_record_id', 'KG:1', 'FINISH_ENTRY_TO_REWASH_LINE',
      'public.finish_rewash_lines', v_line_id, v_line->>'fingerprint', p_sync_run_id,
      jsonb_build_object('finish_rewash_entry_id', v_entry.finish_rewash_entry_id, 'line_no', v_line_no,
        'legacy_entry_type', 'HOUSEHOLD', 'warnings', v_line->'warnings'));

    v_lines := v_lines || jsonb_build_array(v_line || jsonb_build_object('line_no', v_line_no, 'finish_rewash_line_id', v_line_id));
  end loop;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data,
    reason, source_application, correlation_id)
  values (null, null, 'IMPORT_LEGACY_HOUSEHOLD_REWASH', 'finish_rewash_entries', v_entry.finish_rewash_entry_id::text,
    jsonb_build_object('entry', to_jsonb(v_entry), 'lines', v_lines, 'plans', v_result->'plans'),
    'Legacy HOUSEHOLD imported as ReWash (owner decision 2026-10-27)', c_source, p_sync_run_id);

  return v_result - 'mode' - 'writes_performed' || jsonb_build_object(
    'outcome', 'IMPORTED',
    'finish_rewash_entry_id', v_entry.finish_rewash_entry_id,
    'lines_imported', v_line_no);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Privileges: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_plan_finish_entry(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_finish_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_resolve_customer(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_household_rewash(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_household_rewash(uuid,jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_plan_finish_entry(jsonb) to service_role;
grant execute on function integration.legacy_sync_finish_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_plan_household_rewash(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_household_rewash(uuid,jsonb) to service_role;

comment on function integration.legacy_sync_plan_household_rewash(jsonb) is
  'Read-only plan for up to 60 legacy HOUSEHOLD Finish rows as ReWash: per-row blockers, test-day skips and READY Finish cells. Writes nothing.';
comment on function integration.legacy_sync_import_household_rewash(uuid,jsonb) is
  'Imports the legacy HOUSEHOLD rows of one Finish cell as one new ReWash entry, inside an open COMMIT run, when FINISH_REWASH_HISTORICAL_IMPORT is enabled. service_role only.';

commit;
