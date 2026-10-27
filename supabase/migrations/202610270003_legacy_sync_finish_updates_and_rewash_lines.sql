-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270003_legacy_sync_finish_updates_and_rewash_lines
--
-- Owner decisions of 2026-10-27 (Paulo Bressan), after the dry run on the
-- real Apps Script exports of 24-27 October:
--   * a legacy Finish entry keeps changing after it is created: a table can
--     save 0 kg while it is still working on the customer and fill the real
--     value later, up to dispatch. The sync therefore applies a changed
--     legacy entry as a new revision of the V2 entry (never an overwrite);
--     an entry that still has no quantity is not imported yet;
--   * entries already in V2 from the earlier imports (CentralDB 2026-10-23
--     and the local Finish workbook of 2026-10-24) are recognised by the
--     legacy EntryID in their notes and linked, not imported twice. When the
--     legacy values differ, the legacy value wins, as a new revision;
--   * WashItems type OTHERS is Clothes (it is only a washing label);
--   * a legacy HOUSEHOLD Finish row is only the header of a ReWash cell. The
--     customer lines live in the Finish Area sheet RewashProduction. The
--     same customer twice in a cell is summed into one V2 line.
--
-- Changes:
--   1. legacy_sync_record_links: ReWash roles become HOUSEHOLD_TO_REWASH_ENTRY
--      and REWASH_LINE_TO_LINE (the unused FINISH_ENTRY_TO_REWASH_LINE goes).
--   2. Owner-approved value maps for the Finish Area (DONE, Morning/Evening,
--      Table 1-3) and CentralDB (OTHERS -> CLOTHES).
--   3. Finish trigger: an importer-registered LEGACY_SYNC_FINISH row may now
--      also be a revision (revision_no > 1). Everything else is unchanged.
--   4. Sync window: rows before 2026-10-24 are skipped (already imported).
--   5. Staff resolution: legacy user ID, else one exact display-name match.
--   6. NORMAL planner, dry run and importer: CREATE, UPDATE, ADOPT,
--      ADOPT_AND_UPDATE actions and the PENDING_SOURCE outcome.
--   7. The HOUSEHOLD functions of 202610270002 are dropped (never used: the
--      switch stayed OFF and no link exists). New ReWash planner, dry run and
--      importer, one HOUSEHOLD header with its RewashProduction lines per call.
--
-- Both write switches stay OFF. No grant to clients; service_role only.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Links: ReWash roles
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from integration.legacy_sync_record_links where link_role='FINISH_ENTRY_TO_REWASH_LINE') then
    raise exception using errcode='55000',
      message='FINISH_ENTRY_TO_REWASH_LINE links exist. This migration expects the 202610270002 ReWash importer to be unused.';
  end if;
end;
$$;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check,
  drop constraint legacy_sync_record_links_line_key_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='HOUSEHOLD_TO_REWASH_ENTRY' and target_table='public.finish_rewash_entries') or
    (link_role='REWASH_LINE_TO_LINE' and target_table='public.finish_rewash_lines')
  ),
  add constraint legacy_sync_record_links_line_key_check check (
    (link_role='FINISH_ENTRY_TO_LINE' and length(trim(source_line_key)) > 0)
    or (link_role<>'FINISH_ENTRY_TO_LINE' and source_line_key='')
  );

-- ---------------------------------------------------------------------
-- 2. Owner-approved value maps (2026-10-27)
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by, note)
values
  ('FINISH_AREA','FINISH_STATUS','DONE','ACTIVE','Paulo Bressan (owner decision 2026-10-27)','FinishEntries and RewashProduction status of a saved row.'),
  ('FINISH_AREA','SHIFT','Morning','MORNING','Paulo Bressan (owner decision 2026-10-27)',null),
  ('FINISH_AREA','SHIFT','Evening','EVENING','Paulo Bressan (owner decision 2026-10-27)',null),
  ('FINISH_AREA','FINISH_TABLE','Table 1','FINISH_TABLE_1','Paulo Bressan (owner decision 2026-10-27)',null),
  ('FINISH_AREA','FINISH_TABLE','Table 2','FINISH_TABLE_2','Paulo Bressan (owner decision 2026-10-27)',null),
  ('FINISH_AREA','FINISH_TABLE','Table 3','FINISH_TABLE_3','Paulo Bressan (owner decision 2026-10-27)',null),
  ('CENTRALDB','WASH_ITEM_TYPE','OTHERS','CLOTHES','Paulo Bressan (owner decision 2026-10-27)',
   'OTHERS is a washing label only; Finish treats it as Clothes. It may move to MOP in future: retire this row then.')
on conflict (source_system, value_domain, raw_value_key) where retired_at is null do nothing;

-- ---------------------------------------------------------------------
-- 3. Finish trigger: live body (202610270001) with the importer branch
--    open to revisions. The permit still names the exact entry id.
-- ---------------------------------------------------------------------
create or replace function public.finish_enforce_new_entry_current_shift()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare v_auto jsonb; v_expected_shift text;
begin
  -- Legacy sync import: allowed only for the exact entry (first record or
  -- revision) the importer registered in this transaction. The label alone is refused.
  if new.source_application = 'LEGACY_SYNC_FINISH' then
    if auth.uid() is null
       and exists (
         select 1 from integration.legacy_sync_finish_insert_permits p
         where p.transaction_id = pg_current_xact_id()
           and p.finish_production_entry_id = new.finish_production_entry_id
       ) then
      return new;
    end if;
    raise exception using errcode='42501',
      message='LEGACY_SYNC_FINISH entries can only be written by the legacy sync importer.';
  end if;

  if session_user = 'postgres' and auth.uid() is null
     and new.source_application = 'APPS_SCRIPT_CENTRALDB_20261023_001'
     and new.revision_no = 1
     and new.production_business_date between date '2026-09-26' and date '2026-10-23'
     and exists (
       select 1 from staging.apps_script_incremental_rows r
       where r.import_batch = new.source_application and r.decision = 'APPROVED'
         and r.source_sheet in ('FinishProduction','FinishProductionHistory')
         and r.after_snapshot->'plan'->>'kind' = 'FINISH'
         and (r.after_snapshot->'plan'->>'target_id')::uuid = new.finish_production_entry_id
         and (r.after_snapshot->'plan'->>'flow_id')::uuid = new.production_flow_item_id
         and (r.after_snapshot->'plan'->>'customer_id')::uuid = new.customer_id
         and (r.after_snapshot->'plan'->>'business_date')::date = new.production_business_date
         and (r.after_snapshot->'plan'->>'delivery_date')::date = new.delivery_date
         and (r.after_snapshot->'plan'->>'shift_id')::uuid = new.shift_id
         and r.after_snapshot->'plan'->>'shift_code' = new.shift_code_snapshot
         and (r.after_snapshot->'plan'->>'station_id')::uuid = new.station_id
         and r.after_snapshot->'plan'->>'station_code' = new.table_code_snapshot
         and (r.after_snapshot->'plan'->>'staff_id')::uuid = new.processed_by_staff_id
         and (r.after_snapshot->'plan'->>'recorded_at_local')::timestamp at time zone 'Europe/Dublin' = new.recorded_at
     ) then
    return new;
  end if;
  -- Original live and correction behaviour remains in force for every other row.
  if coalesce(new.revision_no,1)=1 then
    v_auto := public.get_finish_auto_shift_context(coalesce(new.recorded_at,now()));
    v_expected_shift := upper(coalesce(v_auto->>'recommended_shift_code',''));
    if v_expected_shift not in ('MORNING','EVENING') then
      raise exception using errcode='P0002', message='Current Finish operational shift could not be resolved.';
    end if;
    if upper(coalesce(new.shift_code_snapshot,''))<>v_expected_shift then
      raise exception using errcode='23514',
        message=format('New Finish production must use the current operational shift (%s). Switch Finish back to Auto/current shift and try again.',initcap(lower(v_expected_shift)));
    end if;
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. Sync window and small helpers
-- ---------------------------------------------------------------------
-- Finish history up to 2026-10-23 came from CentralDB and 2026-10-24 morning
-- from the local workbook. The sync starts on 2026-10-24; older rows are skipped.
create or replace function integration.legacy_sync_finish_window_start()
returns date
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select date '2026-10-24';
$$;

-- Earlier imports name the legacy entry in their notes: "source group FINISH:<EntryID>".
create or replace function integration.legacy_sync_notes_reference(p_notes text, p_entry_id text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_notes is not null and p_entry_id is not null
     and (p_notes || ';') like ('%source group FINISH:' || p_entry_id || ';%');
$$;

-- Processing staff: legacy user ID first; else exactly one staff member whose
-- display name equals the legacy name (case and outer spaces ignored).
-- A name that does not match is kept as a snapshot with a warning.
create or replace function integration.legacy_sync_resolve_staff(p_user_id text, p_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_ids uuid[];
begin
  if p_user_id is not null then
    if p_user_id ~ '^[0-9]{1,9}$' then
      select * into v_staff from public.staff_members sm
      where sm.legacy_user_id = p_user_id::integer and sm.deleted_at is null;
    end if;
    if v_staff.staff_id is null then
      return jsonb_build_object('name', p_name, 'blockers', integration.legacy_sync_issue('STAFF_UNMAPPED', p_user_id),
        'warnings', '[]'::jsonb);
    end if;
    return jsonb_build_object('staff_id', v_staff.staff_id, 'name', v_staff.display_name, 'resolution', 'LEGACY_USER_ID',
      'blockers', '[]'::jsonb, 'warnings', '[]'::jsonb);
  end if;

  if p_name is null then
    return jsonb_build_object('name', null, 'blockers', '[]'::jsonb,
      'warnings', integration.legacy_sync_issue('PROCESSED_BY_NOT_IN_SOURCE'));
  end if;

  select array_agg(sm.staff_id) into v_ids
  from public.staff_members sm
  where sm.deleted_at is null and lower(btrim(sm.display_name)) = lower(btrim(p_name));

  if coalesce(array_length(v_ids,1),0) = 1 then
    select * into v_staff from public.staff_members sm where sm.staff_id = v_ids[1];
    return jsonb_build_object('staff_id', v_staff.staff_id, 'name', v_staff.display_name, 'resolution', 'DISPLAY_NAME',
      'blockers', '[]'::jsonb, 'warnings', '[]'::jsonb);
  end if;
  return jsonb_build_object('name', p_name, 'blockers', '[]'::jsonb,
    'warnings', integration.legacy_sync_issue(
      case when coalesce(array_length(v_ids,1),0) > 1 then 'PROCESSED_BY_NAME_AMBIGUOUS' else 'PROCESSED_BY_NAME_UNMATCHED' end,
      p_name));
end;
$$;

-- Normalised Finish lines of a V2 entry, comparable with a plan's lines.
create or replace function integration.legacy_sync_finish_entry_lines(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('b', upper(l.batch_reference), 'u', l.unit_code, 'q', trim_scale(l.quantity))
                            order by l.unit_code, upper(l.batch_reference), l.quantity), '[]'::jsonb)
  from public.finish_production_lines l
  where l.finish_production_entry_id = p_entry_id;
$$;

create or replace function integration.legacy_sync_plan_lines_key(p_lines jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('b', upper(l->>'batch_reference'), 'u', l->>'unit_code',
                                                'q', trim_scale((l->>'quantity')::numeric))
                            order by l->>'unit_code', upper(l->>'batch_reference'), (l->>'quantity')::numeric), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) l;
$$;

-- ---------------------------------------------------------------------
-- 5. NORMAL planner. Read-only.
--
-- Outcomes: READY (with action CREATE, UPDATE, ADOPT or ADOPT_AND_UPDATE),
-- ALREADY_IMPORTED, PENDING_SOURCE (no quantity yet: retried by the next
-- sync, no review item), SKIPPED (test day or before the sync window),
-- REWASH_ROUTE (HOUSEHOLD) and BLOCKED.
--
-- The V2 target of a legacy entry is, in order: the entry its
-- FINISH_ENTRY_TO_ENTRY link points to, or an entry of an earlier import
-- whose notes name the legacy EntryID. The ACTIVE revision of that entry's
-- group is compared with the legacy values. A change of customer, date,
-- shift, table or flow is never applied automatically.
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
  v_target public.finish_production_entries%rowtype;
  v_target_group uuid;
  v_target_via text;
  v_groups uuid[];
  v_entry_type text;
  v_status_raw text;
  v_status text;
  v_wash_id text;
  v_type text;
  v_product text;
  v_scheduled date;
  v_business date;
  v_delivery date;
  v_cutoff timestamptz;
  v_recorded_at timestamptz;
  v_shift_code text;
  v_table_code text;
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_cust jsonb;
  v_customer public.customers%rowtype;
  v_staff jsonb;
  v_batch text;
  v_kg numeric;
  v_units numeric;
  v_total numeric;
  v_no_quantity boolean := false;
  v_lines jsonb := '[]'::jsonb;
  v_flow public.production_flow_items%rowtype;
  v_flow_action text;
  v_snapshot record;
  v_schedule jsonb;
  v_identity text[] := array[]::text[];
  v_same_lines boolean;
  v_same_staff boolean;
  v_action text;
  v_outcome text;
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

  -- V2 target: our own link first, then an earlier import that names the EntryID.
  select * into v_link
  from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role='FINISH_ENTRY_TO_ENTRY';
  if found then
    v_target_via := 'LINK';
    select e.entry_group_id into v_target_group
    from public.finish_production_entries e where e.finish_production_entry_id=v_link.target_id;
  elsif v_id is not null then
    select array_agg(distinct e.entry_group_id) into v_groups
    from public.finish_production_entries e
    where e.source_application in ('APPS_SCRIPT_CENTRALDB_20261023_001','LOCAL_FINISH_WORKBOOK_20261024')
      and integration.legacy_sync_notes_reference(e.notes, v_id);
    if coalesce(array_length(v_groups,1),0) = 1 then
      v_target_via := 'LEGACY_NOTE';
      v_target_group := v_groups[1];
    elsif coalesce(array_length(v_groups,1),0) > 1 then
      v_blockers := v_blockers || integration.legacy_sync_issue('LEGACY_NOTE_AMBIGUOUS',
        'More than one V2 Finish entry names this legacy EntryID.');
    end if;
  end if;
  if v_target_group is not null then
    select * into v_target from public.finish_production_entries e
    where e.entry_group_id=v_target_group and e.status='ACTIVE';
    if not found then
      v_blockers := v_blockers || integration.legacy_sync_issue('TARGET_NOT_ACTIVE',
        'The V2 Finish entry of this legacy entry is no longer ACTIVE (cancelled in V2).');
    end if;
  end if;

  -- Owner decision 2026-10-27: every legacy row of Sunday 2026-10-25 was a test.
  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_entry,'BusinessDate'));
  if v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_business < integration.legacy_sync_finish_window_start() and v_target_via is distinct from 'LINK' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- Entry type: NORMAL is imported here. HOUSEHOLD is ReWash (owner decision 2026-10-27).
  v_entry_type := upper(integration.legacy_sync_text(v_entry,'EntryType'));
  if v_entry_type = 'HOUSEHOLD' then
    return jsonb_build_object('outcome','REWASH_ROUTE','source_record_id',v_id,'fingerprint',v_fp,
      'blockers','[]'::jsonb,'warnings','[]'::jsonb,
      'detail','HOUSEHOLD is imported as ReWash through integration.legacy_sync_import_rewash_cell.');
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

  -- Customer.
  v_cust := integration.legacy_sync_resolve_customer(integration.legacy_sync_text(v_entry,'CustomerID'));
  v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
  if v_cust->>'customer_id' is not null then
    select * into v_customer from public.customers c where c.customer_id=(v_cust->>'customer_id')::uuid;
    if not v_customer.active then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_INACTIVE_PENDING_DECISION', v_customer.customer_code);
    end if;
  end if;

  -- Processing staff.
  v_staff := integration.legacy_sync_resolve_staff(integration.legacy_sync_text(v_entry,'StaffUserID'),
                                                   integration.legacy_sync_text(v_entry,'StaffName'));
  v_blockers := v_blockers || coalesce(v_staff->'blockers','[]'::jsonb);
  v_warnings := v_warnings || coalesce(v_staff->'warnings','[]'::jsonb);

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
    -- Owner 2026-10-27: 0 means the table is still working on the customer.
    if v_target_group is not null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_QUANTITY_REMOVED',
        'The legacy entry now has no quantity, but V2 already has this entry.');
    else
      v_no_quantity := true;
    end if;
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
    elsif v_target_group is null then
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
                   and e.table_code_snapshot=v_table_code
                   and e.entry_group_id is distinct from v_target_group) then
        v_blockers := v_blockers || integration.legacy_sync_issue('CELL_HAS_ACTIVE_ENTRY',
          'The flow already has an ACTIVE Finish entry for this date, shift and table.');
      end if;
    end if;
  end if;

  -- Batch reference must be free on the business date and on the flow (own entry excluded).
  if v_batch is not null and v_business is not null and exists (
       select 1 from public.finish_production_entries e
       join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
       where e.status='ACTIVE' and lower(l.batch_reference)=lower(v_batch)
         and e.entry_group_id is distinct from v_target_group
         and (e.production_business_date=v_business
              or (v_flow.production_flow_item_id is not null and e.production_flow_item_id=v_flow.production_flow_item_id))) then
    v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_IN_USE', v_batch);
  end if;

  -- An existing V2 entry may take new quantities, batch or staff, never a new identity.
  if v_target.finish_production_entry_id is not null then
    if v_customer.customer_id is distinct from v_target.customer_id then v_identity := v_identity || 'customer'::text; end if;
    if v_business is distinct from v_target.production_business_date then v_identity := v_identity || 'business_date'::text; end if;
    if v_shift_code is distinct from v_target.shift_code_snapshot then v_identity := v_identity || 'shift'::text; end if;
    if v_table_code is distinct from v_target.table_code_snapshot then v_identity := v_identity || 'table'::text; end if;
    if v_flow.production_flow_item_id is distinct from v_target.production_flow_item_id then v_identity := v_identity || 'scheduled_date'::text; end if;
    if cardinality(v_identity) > 0 then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_IDENTITY_CHANGED',
        'Differs from the V2 entry in: '||array_to_string(v_identity, ', '));
    end if;
    v_same_lines := integration.legacy_sync_plan_lines_key(v_lines)
                    = integration.legacy_sync_finish_entry_lines(v_target.finish_production_entry_id);
    v_same_staff := v_staff->>'staff_id' is null
                    or (v_staff->>'staff_id')::uuid is not distinct from v_target.processed_by_staff_id;
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    v_outcome := 'BLOCKED';
  elsif v_no_quantity then
    v_outcome := 'PENDING_SOURCE';
  elsif v_target.finish_production_entry_id is null then
    v_outcome := 'READY'; v_action := 'CREATE';
  elsif v_target_via = 'LINK' and v_same_lines and v_same_staff then
    v_outcome := 'ALREADY_IMPORTED';
  elsif v_target_via = 'LINK' then
    v_outcome := 'READY'; v_action := 'UPDATE';
  elsif v_same_lines and v_same_staff then
    v_outcome := 'READY'; v_action := 'ADOPT';
  else
    v_outcome := 'READY'; v_action := 'ADOPT_AND_UPDATE';
  end if;

  return jsonb_build_object(
    'outcome', v_outcome,
    'action', v_action,
    'source_record_id', v_id,
    'fingerprint', v_fp,
    'wash_item_fingerprint', v_wash_fp,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'target', case when v_target_group is not null then jsonb_build_object(
      'via', v_target_via,
      'entry_group_id', v_target_group,
      'finish_production_entry_id', v_target.finish_production_entry_id,
      'revision_no', v_target.revision_no,
      'source_application', v_target.source_application,
      'lines', case when v_target.finish_production_entry_id is not null
                    then integration.legacy_sync_finish_entry_lines(v_target.finish_production_entry_id) end,
      'processed_by_staff_id', v_target.processed_by_staff_id) end,
    'resolved', jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_resolution', v_cust->>'resolution',
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
      'processed_by_staff_id', v_staff->>'staff_id',
      'processed_by_name', v_staff->>'name',
      'processed_by_resolution', v_staff->>'resolution',
      'flow_action', v_flow_action,
      'production_flow_item_id', v_flow.production_flow_item_id,
      'flow_code', v_flow.flow_code,
      'schedule', v_schedule,
      'trolley_codes_raw', integration.legacy_sync_text(v_entry,'Trolleys')),
    'lines', v_lines,
    'totals', jsonb_build_object('kg', coalesce(v_kg,0), 'units', coalesce(v_units,0)));
end;
$$;

-- ---------------------------------------------------------------------
-- 6. NORMAL dry run: also counts PENDING_SOURCE and the READY actions
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

  -- Batch-level checks: the same legacy entry twice, two new entries in one
  -- Finish cell (owner decision), the same new batch reference twice in a day.
  for v_plan in select value from jsonb_array_elements(v_plans) loop
    v_extra := '[]'::jsonb;
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id') > 1 then
      v_extra := v_extra || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH');
    end if;
    if v_plan->'target' is null and v_plan#>>'{resolved,customer_id}' is not null and (
        select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' is distinct from v_plan->>'source_record_id'
          and o->'target' is null
          and o->>'outcome' in ('READY','BLOCKED')
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
          and o->>'outcome' in ('READY','BLOCKED')
          and lower(o#>>'{lines,0,batch_reference}') = lower(v_plan#>>'{lines,0,batch_reference}')
          and o#>>'{resolved,production_business_date}' = v_plan#>>'{resolved,production_business_date}') > 0 then
      v_extra := v_extra || integration.legacy_sync_issue('BATCH_REFERENCE_DUPLICATE_IN_BATCH', v_plan#>>'{lines,0,batch_reference}');
    end if;
    if jsonb_array_length(v_extra) > 0 and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || v_extra);
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
  end loop;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'actions', (select coalesce(jsonb_object_agg(a, n),'{}'::jsonb) from (
        select o->>'action' as a, count(*) as n from jsonb_array_elements(v_out) o
        where o->>'outcome'='READY' group by 1) x),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'pending_source', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='PENDING_SOURCE'),
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
-- 7. Record versions and review items shared by both importers
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_keep_version(
  p_source_system text, p_source_table text, p_source_record_id text,
  p_fingerprint text, p_payload jsonb, p_sync_run_id uuid)
returns void
language sql
security definer
set search_path = public, integration, pg_temp
as $$
  insert into integration.legacy_sync_record_versions(source_system, source_table, source_record_id,
    source_fingerprint, payload, first_seen_run)
  select p_source_system, p_source_table, p_source_record_id, p_fingerprint, p_payload, p_sync_run_id
  where p_source_record_id is not null and p_fingerprint is not null and p_payload is not null
  on conflict on constraint legacy_sync_record_versions_uq do nothing;
$$;

create or replace function integration.legacy_sync_hold_for_review(
  p_source_system text, p_source_table text, p_plan jsonb, p_record jsonb, p_sync_run_id uuid)
returns void
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_id text := p_plan->>'source_record_id';
  v_blocker jsonb;
begin
  if v_id is null then
    return;
  end if;
  if p_plan->>'outcome' = 'SKIPPED' and p_plan->>'skip_reason' = 'OWNER_TEST_DAY' then
    insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id, reason_code,
      raw, status, decision, decided_by, decided_at, sync_run_id)
    select p_source_system, p_source_table, v_id, 'OWNER_TEST_DAY',
      jsonb_build_object('record', p_record, 'fingerprint', p_plan->>'fingerprint'),
      'REJECTED', jsonb_build_object('action','NOT_IMPORTED','rule','All legacy rows of Sunday 2026-10-25 were owner tests.'),
      'Owner decision 2026-10-27', now(), p_sync_run_id
    where not exists (select 1 from integration.legacy_sync_review_items ri
                      where ri.source_system=p_source_system and ri.source_table=p_source_table
                        and ri.source_record_id=v_id and ri.reason_code='OWNER_TEST_DAY');
  elsif p_plan->>'outcome' = 'BLOCKED' then
    for v_blocker in select value from jsonb_array_elements(coalesce(p_plan->'blockers','[]'::jsonb)) loop
      insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id,
        reason_code, raw, sync_run_id)
      values (p_source_system, p_source_table, v_id, v_blocker->>'code',
        jsonb_build_object('record', p_record, 'detail', v_blocker->>'detail', 'fingerprint', p_plan->>'fingerprint'),
        p_sync_run_id)
      on conflict (source_system, source_table, source_record_id, reason_code) where status='OPEN' do nothing;
    end loop;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. NORMAL importer: one legacy Finish entry, one transaction.
--    CREATE writes revision 1. UPDATE supersedes the ACTIVE revision and
--    writes the next one (the old row stays, status SUPERSEDED). ADOPT links
--    an entry of an earlier import; ADOPT_AND_UPDATE links it, then updates.
--    The run limit counts writing actions (audit rows of the run).
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_finish_entry(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  c_wash_system constant text := 'CENTRALDB';
  c_wash_table constant text := 'WashItems';
  c_source constant text := 'LEGACY_SYNC_FINISH';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_plan jsonb;
  v_r jsonb;
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_flow_id uuid;
  v_flow public.production_flow_items%rowtype;
  v_old public.finish_production_entries%rowtype;
  v_new public.finish_production_entries%rowtype;
  v_entry_id uuid := gen_random_uuid();
  v_line jsonb;
  v_line_id uuid;
  v_event_id uuid;
  v_done integer;
  v_action text;
  v_note text;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='FINISH_HISTORICAL_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy Finish historical import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  -- Serialize retries of the same legacy entry.
  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_FINISH:'||v_id, 0));

  v_plan := integration.legacy_sync_plan_finish_entry(p_record);

  -- Keep every distinct source version (insert-only, idempotent).
  perform integration.legacy_sync_keep_version(c_system, c_table, v_id, v_plan->>'fingerprint', p_record->'entry', p_sync_run_id);
  perform integration.legacy_sync_keep_version(c_wash_system, c_wash_table, v_plan#>>'{resolved,wash_item_id}',
    v_plan->>'wash_item_fingerprint', p_record->'wash_item', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(c_system, c_table, v_plan, p_record, p_sync_run_id);
    return v_plan;
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_FINISH_ENTRY','UPDATE_LEGACY_FINISH_ENTRY','ADOPT_LEGACY_FINISH_ENTRY');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_r := v_plan->'resolved';
  v_action := v_plan->>'action';
  v_note := 'Legacy Finish sync; source group FINISH:'||v_id;

  -- Serialize writers of the same flow key.
  perform pg_advisory_xact_lock(hashtextextended(
    'FLOW:'||(v_r->>'customer_id')||':CLOTHES:'||(v_r->>'scheduled_for_date'), 0));

  if v_action = 'CREATE' then
    v_flow_id := public.ensure_production_flow_item(
      (v_r->>'customer_id')::uuid, 'CLOTHES', (v_r->>'scheduled_for_date')::date,
      (v_r->>'production_business_date')::date,
      nullif(v_r#>>'{schedule,schedule_version_id}','')::uuid,
      nullif(v_r#>>'{schedule,schedule_day_id}','')::uuid,
      nullif(v_r#>>'{schedule,schedule_product_id}','')::uuid,
      nullif(v_r#>>'{schedule,production_order}','')::integer,
      nullif(v_r#>>'{schedule,route_id}','')::uuid,
      v_r#>>'{schedule,route_code}', v_r#>>'{schedule,route_display_name}', v_r#>>'{schedule,route_color}');
  else
    v_flow_id := (v_r->>'production_flow_item_id')::uuid;
  end if;

  select * into v_flow from public.production_flow_items where production_flow_item_id=v_flow_id for update;
  if v_flow.customer_id <> (v_r->>'customer_id')::uuid or v_flow.product_code <> 'CLOTHES'
     or v_flow.scheduled_for_date is distinct from (v_r->>'scheduled_for_date')::date then
    raise exception using errcode='23514', message='Resolved Production Flow does not match the canonical key.';
  end if;
  if v_r->>'production_flow_item_id' is not null and v_flow_id <> (v_r->>'production_flow_item_id')::uuid then
    raise exception using errcode='40001', message='Production Flow changed during import. Retry.';
  end if;

  -- Re-check cell and batch under the flow lock (the plan ran before it).
  if exists (select 1 from public.finish_production_entries e
             where e.production_flow_item_id=v_flow_id and e.status='ACTIVE'
               and e.production_business_date=(v_r->>'production_business_date')::date
               and e.shift_code_snapshot=v_r->>'shift_code' and e.table_code_snapshot=v_r->>'table_code'
               and e.entry_group_id is distinct from nullif(v_plan#>>'{target,entry_group_id}','')::uuid) then
    raise exception using errcode='23505', message='The flow already has an ACTIVE Finish entry for this cell.';
  end if;
  if exists (select 1 from public.finish_production_entries e
             join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
             where e.status='ACTIVE' and lower(l.batch_reference)=lower(v_plan#>>'{lines,0,batch_reference}')
               and e.entry_group_id is distinct from nullif(v_plan#>>'{target,entry_group_id}','')::uuid
               and (e.production_business_date=(v_r->>'production_business_date')::date or e.production_flow_item_id=v_flow_id)) then
    raise exception using errcode='23505', message='Batch reference is already used by an ACTIVE Finish entry.';
  end if;

  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
  select c_wash_system, c_wash_table, v_r->>'wash_item_id', 'WASH_ITEM_TO_FLOW',
    'public.production_flow_items', v_flow_id, v_plan->>'wash_item_fingerprint', p_sync_run_id,
    jsonb_build_object('scheduled_for_date', v_r->>'scheduled_for_date', 'first_finish_entry', v_id)
  where not exists (select 1 from integration.legacy_sync_record_links l
                    where l.source_system=c_wash_system and l.source_table=c_wash_table
                      and l.source_record_id=v_r->>'wash_item_id' and l.link_role='WASH_ITEM_TO_FLOW');

  -- ---- CREATE -------------------------------------------------------
  if v_action = 'CREATE' then
    insert into integration.legacy_sync_finish_insert_permits(transaction_id, finish_production_entry_id)
    values (pg_current_xact_id(), v_entry_id);

    insert into public.finish_production_entries(
      finish_production_entry_id, entry_group_id, revision_no, status, production_flow_item_id, customer_id,
      production_business_date, delivery_date, edit_cutoff_at, shift_id, shift_code_snapshot,
      station_id, table_code_snapshot, table_name_snapshot, notes, source_application, recorded_at,
      recorded_by_staff_id, recorded_by_auth_user_id, processed_by_staff_id, processed_by_name_snapshot,
      trolley_scan_status)
    values (
      v_entry_id, gen_random_uuid(), 1, 'ACTIVE', v_flow_id, (v_r->>'customer_id')::uuid,
      (v_r->>'production_business_date')::date, (v_r->>'delivery_date')::date, (v_r->>'edit_cutoff_at')::timestamptz,
      (v_r->>'shift_id')::uuid, v_r->>'shift_code', (v_r->>'station_id')::uuid, v_r->>'table_code', v_r->>'table_name',
      v_note, c_source, (v_r->>'recorded_at')::timestamptz,
      null, null, nullif(v_r->>'processed_by_staff_id','')::uuid, v_r->>'processed_by_name',
      'UNSPECIFIED');

    delete from integration.legacy_sync_finish_insert_permits
    where transaction_id=pg_current_xact_id() and finish_production_entry_id=v_entry_id;

    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'FINISH_ENTRY_TO_ENTRY', 'public.finish_production_entries', v_entry_id,
      v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('wash_item_id', v_r->>'wash_item_id', 'trolley_codes_raw', v_r->>'trolley_codes_raw',
        'warnings', v_plan->'warnings'));

    for v_line in select value from jsonb_array_elements(v_plan->'lines') loop
      insert into public.finish_production_lines(finish_production_entry_id, line_no, batch_reference, unit_code, quantity)
      values (v_entry_id, (v_line->>'line_no')::integer, v_line->>'batch_reference', v_line->>'unit_code',
        (v_line->>'quantity')::numeric)
      returning finish_production_line_id into v_line_id;

      insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id,
        source_line_key, link_role, target_table, target_id, source_fingerprint, sync_run_id)
      values (c_system, c_table, v_id, v_line->>'source_line_key', 'FINISH_ENTRY_TO_LINE',
        'public.finish_production_lines', v_line_id, v_plan->>'fingerprint', p_sync_run_id);
    end loop;

    v_event_id := public.append_production_flow_event(
      v_flow_id, 'FINISH_PRODUCTION_RECORDED', 'PRODUCTION', 40, 'FINISH',
      (v_r->>'production_business_date')::date, (v_r->>'recorded_at')::timestamptz,
      nullif(v_r->>'processed_by_staff_id','')::uuid, null, null,
      c_source, 'finish_production_entries', v_entry_id::text,
      jsonb_build_object(
        'legacy_source_system', c_system, 'legacy_entry_id', v_id,
        'legacy_wash_item_id', v_r->>'wash_item_id', 'sync_run_id', p_sync_run_id,
        'table_code', v_r->>'table_code', 'shift_code', v_r->>'shift_code',
        'delivery_date', v_r->>'delivery_date', 'processed_kg', v_plan#>'{totals,kg}',
        'processed_units', v_plan#>'{totals,units}', 'trolley_codes_raw', v_r->>'trolley_codes_raw',
        'trolley_lifecycle', 'NOT_RECORDED_HISTORICAL_IMPORT'));

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data,
      reason, source_application, correlation_id)
    values (null, null, 'IMPORT_LEGACY_FINISH_ENTRY', 'finish_production_entries', v_entry_id::text,
      jsonb_build_object('plan', v_plan, 'production_flow_item_id', v_flow_id, 'flow_event_id', v_event_id),
      'Legacy Finish sync', c_source, p_sync_run_id);

    return v_plan || jsonb_build_object('outcome', 'IMPORTED', 'finish_production_entry_id', v_entry_id,
      'production_flow_item_id', v_flow_id, 'flow_event_id', v_event_id);
  end if;

  -- ---- Existing V2 entry: lock its ACTIVE revision ------------------
  select * into v_old from public.finish_production_entries e
  where e.finish_production_entry_id=(v_plan#>>'{target,finish_production_entry_id}')::uuid
  for update;
  if not found or v_old.status <> 'ACTIVE' or v_old.production_flow_item_id <> v_flow_id then
    raise exception using errcode='40001', message='The V2 Finish entry changed during import. Retry.';
  end if;

  if v_action in ('ADOPT','ADOPT_AND_UPDATE') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'FINISH_ENTRY_TO_ENTRY', 'public.finish_production_entries', v_old.finish_production_entry_id,
      v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted_from', v_old.source_application, 'revision_no', v_old.revision_no,
        'wash_item_id', v_r->>'wash_item_id', 'trolley_codes_raw', v_r->>'trolley_codes_raw', 'warnings', v_plan->'warnings'));

    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id,
      source_line_key, link_role, target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    select c_system, c_table, v_id, l.unit_code||':'||l.line_no, 'FINISH_ENTRY_TO_LINE',
      'public.finish_production_lines', l.finish_production_line_id, v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted_from', v_old.source_application)
    from public.finish_production_lines l
    where l.finish_production_entry_id=v_old.finish_production_entry_id;

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data,
      reason, source_application, correlation_id)
    values (null, null, 'ADOPT_LEGACY_FINISH_ENTRY', 'finish_production_entries', v_old.finish_production_entry_id::text,
      jsonb_build_object('plan', v_plan), 'Legacy Finish sync: entry already in V2 from '||v_old.source_application,
      c_source, p_sync_run_id);

    if v_action = 'ADOPT' then
      return v_plan || jsonb_build_object('outcome', 'ADOPTED', 'finish_production_entry_id', v_old.finish_production_entry_id);
    end if;
  end if;

  -- ---- UPDATE: new revision, old one SUPERSEDED ---------------------
  update public.finish_production_entries set status='SUPERSEDED'
  where finish_production_entry_id=v_old.finish_production_entry_id;

  insert into integration.legacy_sync_finish_insert_permits(transaction_id, finish_production_entry_id)
  values (pg_current_xact_id(), v_entry_id);

  insert into public.finish_production_entries(
    finish_production_entry_id, entry_group_id, revision_no, status, supersedes_finish_production_entry_id,
    production_flow_item_id, customer_id, production_business_date, delivery_date, edit_cutoff_at,
    shift_id, shift_code_snapshot, station_id, table_code_snapshot, table_name_snapshot,
    notes, correction_reason, source_application, recorded_by_staff_id, recorded_by_auth_user_id,
    processed_by_staff_id, processed_by_name_snapshot, trolley_scan_status)
  values (
    v_entry_id, v_old.entry_group_id, v_old.revision_no+1, 'ACTIVE', v_old.finish_production_entry_id,
    v_old.production_flow_item_id, v_old.customer_id, v_old.production_business_date, v_old.delivery_date, v_old.edit_cutoff_at,
    v_old.shift_id, v_old.shift_code_snapshot, v_old.station_id, v_old.table_code_snapshot, v_old.table_name_snapshot,
    v_note, 'Legacy Finish entry changed in the Apps Script sheet', c_source, null, null,
    coalesce(nullif(v_r->>'processed_by_staff_id','')::uuid, v_old.processed_by_staff_id),
    coalesce(v_r->>'processed_by_name', v_old.processed_by_name_snapshot), v_old.trolley_scan_status)
  returning * into v_new;

  delete from integration.legacy_sync_finish_insert_permits
  where transaction_id=pg_current_xact_id() and finish_production_entry_id=v_entry_id;

  for v_line in select value from jsonb_array_elements(v_plan->'lines') loop
    insert into public.finish_production_lines(finish_production_entry_id, line_no, batch_reference, unit_code, quantity)
    values (v_entry_id, (v_line->>'line_no')::integer, v_line->>'batch_reference', v_line->>'unit_code',
      (v_line->>'quantity')::numeric);
  end loop;

  -- Trolley links move with the revision, as in correct_finish_production; custody is not touched.
  insert into public.finish_production_trolleys(finish_production_entry_id, trolley_id, trolley_code_snapshot, stay_id)
  select v_entry_id, t.trolley_id, t.trolley_code_snapshot, t.stay_id
  from public.finish_production_trolleys t where t.finish_production_entry_id=v_old.finish_production_entry_id;

  v_event_id := public.append_production_flow_event(
    v_flow_id, 'FINISH_PRODUCTION_CORRECTED', 'PRODUCTION', 40, 'FINISH',
    v_old.production_business_date, now(),
    v_new.processed_by_staff_id, null, null,
    c_source, 'finish_production_entries', v_entry_id::text,
    jsonb_build_object(
      'legacy_source_system', c_system, 'legacy_entry_id', v_id, 'sync_run_id', p_sync_run_id,
      'entry_group_id', v_old.entry_group_id, 'revision_no', v_new.revision_no,
      'supersedes', v_old.finish_production_entry_id,
      'processed_kg', v_plan#>'{totals,kg}', 'processed_units', v_plan#>'{totals,units}',
      'correction_reason', v_new.correction_reason));

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data,
    reason, source_application, correlation_id)
  values (null, null, 'UPDATE_LEGACY_FINISH_ENTRY', 'finish_production_entries', v_entry_id::text,
    jsonb_build_object('entry', to_jsonb(v_old), 'lines', v_plan#>'{target,lines}'),
    jsonb_build_object('entry', to_jsonb(v_new), 'plan', v_plan, 'flow_event_id', v_event_id),
    v_new.correction_reason, c_source, p_sync_run_id);

  return v_plan || jsonb_build_object(
    'outcome', case when v_action='ADOPT_AND_UPDATE' then 'ADOPTED_AND_UPDATED' else 'UPDATED' end,
    'finish_production_entry_id', v_entry_id,
    'supersedes_finish_production_entry_id', v_old.finish_production_entry_id,
    'revision_no', v_new.revision_no,
    'production_flow_item_id', v_flow_id,
    'flow_event_id', v_event_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. ReWash from legacy HOUSEHOLD headers and RewashProduction lines
-- ---------------------------------------------------------------------
drop function if exists integration.legacy_sync_import_household_rewash(uuid, jsonb);
drop function if exists integration.legacy_sync_plan_household_rewash(jsonb);

-- Normalised ReWash lines of a V2 entry, comparable with a plan's lines.
create or replace function integration.legacy_sync_rewash_entry_lines(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('c', l.customer_id, 'b', upper(l.batch_reference), 'q', trim_scale(l.quantity_kg))
                            order by l.customer_id, l.quantity_kg), '[]'::jsonb)
  from public.finish_rewash_lines l
  where l.finish_rewash_entry_id = p_entry_id;
$$;

-- p_record:
-- {
--   "source_record_id": "<FinishEntries.EntryID of the HOUSEHOLD header>",
--   "entry": { FinishEntries row: EntryID, CreatedAt, BusinessDate, Shift, TableID,
--              EntryType (HOUSEHOLD), Status, QtyKg, BatchNo, Notes, StaffName or StaffUserID },
--   "lines": [ RewashProduction rows of that EntryID: RewashLineID, EntryID, LineNo,
--              BusinessDate, Shift, TableID, CustomerID, BatchNo, QtyKg, QtyUnits, Status ]
-- }
-- One header is one V2 ReWash cell (date, shift, table). The same customer
-- twice is summed into one KG line (owner decision 2026-10-27). A 0 kg line
-- is left out until the table fills it in. Read-only.
create or replace function integration.legacy_sync_plan_rewash_cell(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  c_line_table constant text := 'RewashProduction';
  v_entry jsonb := coalesce(p_record->'entry', 'null'::jsonb);
  v_src_lines jsonb := coalesce(p_record->'lines', 'null'::jsonb);
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_target public.finish_rewash_entries%rowtype;
  v_cell_entry public.finish_rewash_entries%rowtype;
  v_target_group uuid;
  v_target_via text;
  v_status text;
  v_business date;
  v_recorded_at timestamptz;
  v_shift_code text;
  v_table_code text;
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_staff jsonb;
  v_options jsonb;
  v_line jsonb;
  v_line_id text;
  v_seen text[] := array[]::text[];
  v_line_status text;
  v_line_kg numeric;
  v_line_units numeric;
  v_line_batch text;
  v_cust jsonb;
  v_option jsonb;
  v_parts jsonb := '[]'::jsonb;
  v_source_lines jsonb := '[]'::jsonb;
  v_included boolean;
  v_lines jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_header_kg numeric;
  v_no_quantity boolean := false;
  v_same boolean;
  v_outcome text;
  v_action text;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or jsonb_typeof(v_entry) <> 'object'
     or jsonb_typeof(v_src_lines) <> 'array' then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','The record must contain an entry object and a lines array.'));
  end if;
  if jsonb_array_length(v_src_lines) > 200 then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('TOO_MANY_LINES','A ReWash cell can carry at most 200 legacy lines.'));
  end if;

  if v_id is null or length(v_id) > 300 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  elsif integration.legacy_sync_text(v_entry,'EntryID') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH','source_record_id differs from entry.EntryID.');
  end if;

  v_fp := integration.legacy_sync_fingerprint(v_entry);

  -- Owner decision 2026-10-27: every legacy row of Sunday 2026-10-25 was a test.
  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_entry,'BusinessDate'));
  if v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  select * into v_link
  from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role in ('HOUSEHOLD_TO_REWASH_ENTRY','FINISH_ENTRY_TO_ENTRY')
  order by l.created_at
  limit 1;
  if found and v_link.link_role = 'FINISH_ENTRY_TO_ENTRY' then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,'fingerprint',v_fp,
      'blockers', integration.legacy_sync_issue('IMPORTED_AS_NORMAL_ENTRY',
        'This legacy entry was already imported as a Finish production entry.'));
  elsif found then
    v_target_via := 'LINK';
    select e.entry_group_id into v_target_group
    from public.finish_rewash_entries e where e.finish_rewash_entry_id=v_link.target_id;
  end if;

  if v_business < integration.legacy_sync_finish_window_start() and v_target_via is null then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if upper(integration.legacy_sync_text(v_entry,'EntryType')) is distinct from 'HOUSEHOLD' then
    v_blockers := v_blockers || integration.legacy_sync_issue('ENTRY_TYPE_NOT_HOUSEHOLD',
      integration.legacy_sync_text(v_entry,'EntryType'));
  end if;

  v_status := integration.legacy_sync_map_value(c_system,'FINISH_STATUS',integration.legacy_sync_text(v_entry,'Status'));
  if v_status is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_STATUS_UNMAPPED', integration.legacy_sync_text(v_entry,'Status'));
  elsif v_status <> 'ACTIVE' then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_NOT_ACTIVE', integration.legacy_sync_text(v_entry,'Status'));
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

  v_staff := integration.legacy_sync_resolve_staff(integration.legacy_sync_text(v_entry,'StaffUserID'),
                                                   integration.legacy_sync_text(v_entry,'StaffName'));
  v_blockers := v_blockers || coalesce(v_staff->'blockers','[]'::jsonb);
  v_warnings := v_warnings || coalesce(v_staff->'warnings','[]'::jsonb);

  -- V2 target: our own link, else the ACTIVE entry of the cell if an earlier
  -- import wrote it. An entry recorded in the V2 app is never taken over.
  if v_target_group is not null then
    select * into v_target from public.finish_rewash_entries e
    where e.entry_group_id=v_target_group and e.status='ACTIVE';
    if not found then
      v_blockers := v_blockers || integration.legacy_sync_issue('TARGET_NOT_ACTIVE',
        'The V2 ReWash entry of this legacy header is no longer ACTIVE.');
    end if;
  elsif v_business is not null and v_shift_code is not null and v_table_code is not null then
    select * into v_cell_entry from public.finish_rewash_entries e
    where e.status='ACTIVE' and e.production_business_date=v_business
      and e.shift_code_snapshot=v_shift_code and e.table_code_snapshot=v_table_code;
    if found then
      if exists (select 1 from integration.legacy_sync_record_links l
                 join public.finish_rewash_entries t on t.finish_rewash_entry_id=l.target_id
                 where l.link_role='HOUSEHOLD_TO_REWASH_ENTRY' and t.entry_group_id=v_cell_entry.entry_group_id) then
        v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_CELL_LINKED_TO_OTHER_SOURCE',
          'Another legacy HOUSEHOLD header already feeds this ReWash cell.');
      elsif v_cell_entry.recorded_by_auth_user_id is not null or v_cell_entry.recorded_by_staff_id is not null then
        v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_CELL_HAS_V2_ENTRY',
          'The ReWash cell was recorded in the V2 app. It is not taken over automatically.');
      else
        v_target := v_cell_entry;
        v_target_group := v_cell_entry.entry_group_id;
        v_target_via := 'CELL';
      end if;
    end if;
  end if;

  -- Lines.
  if v_business is not null then
    v_options := public.finish_rewash_customer_options_v1(v_business);
  end if;
  for v_line in select value from jsonb_array_elements(v_src_lines) loop
    v_included := false;
    v_line_id := integration.legacy_sync_text(v_line,'RewashLineID');
    v_cust := null; v_option := null; v_line_kg := null; v_line_units := null;
    if jsonb_typeof(v_line) <> 'object' or v_line_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('LINE_MISSING_ID');
      continue;
    end if;
    if v_line_id = any(v_seen) then
      v_blockers := v_blockers || integration.legacy_sync_issue('LINE_DUPLICATE_ID', v_line_id);
      continue;
    end if;
    v_seen := v_seen || v_line_id;
    if integration.legacy_sync_text(v_line,'EntryID') is distinct from v_id then
      v_blockers := v_blockers || integration.legacy_sync_issue('LINE_ENTRY_MISMATCH', v_line_id);
    end if;
    if integration.legacy_sync_parse_date(integration.legacy_sync_text(v_line,'BusinessDate')) is distinct from v_business
       or integration.legacy_sync_map_value(c_system,'SHIFT',integration.legacy_sync_text(v_line,'Shift')) is distinct from v_shift_code
       or integration.legacy_sync_map_value(c_system,'FINISH_TABLE',integration.legacy_sync_text(v_line,'TableID')) is distinct from v_table_code then
      v_blockers := v_blockers || integration.legacy_sync_issue('LINE_CELL_MISMATCH', v_line_id);
    end if;

    v_line_status := integration.legacy_sync_map_value(c_system,'FINISH_STATUS',integration.legacy_sync_text(v_line,'Status'));
    if v_line_status is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('LINE_STATUS_UNMAPPED',
        v_line_id||': '||coalesce(integration.legacy_sync_text(v_line,'Status'),'(empty)'));
    end if;

    if integration.legacy_sync_text(v_line,'QtyUnits') is not null then
      v_line_units := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_line,'QtyUnits'));
      if v_line_units is null then
        v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY', v_line_id||' QtyUnits');
      elsif v_line_units <> 0 then
        v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_UNITS_NOT_SUPPORTED', v_line_id);
      end if;
    end if;
    v_line_kg := integration.legacy_sync_parse_number(coalesce(integration.legacy_sync_text(v_line,'QtyKg'),'0'));
    if v_line_kg is null or v_line_kg < 0 or v_line_kg > 10000 or v_line_kg <> round(v_line_kg,2) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY',
        v_line_id||' QtyKg='||coalesce(integration.legacy_sync_text(v_line,'QtyKg'),''));
      v_line_kg := null;
    end if;

    v_line_batch := upper(integration.legacy_sync_text(v_line,'BatchNo'));
    if v_line_batch is not null and length(v_line_batch) > 120 then
      v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_TOO_LONG', v_line_id);
    end if;

    if v_line_status = 'ACTIVE' and v_line_kg = 0 then
      v_warnings := v_warnings || integration.legacy_sync_issue('ZERO_KG_LINE_WAITING', v_line_id);
    elsif v_line_status = 'ACTIVE' and v_line_kg > 0 then
      v_cust := integration.legacy_sync_resolve_customer(integration.legacy_sync_text(v_line,'CustomerID'));
      v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
      if v_cust->>'customer_id' is not null then
        select opt into v_option from jsonb_array_elements(coalesce(v_options,'[]'::jsonb)) opt
        where opt->>'customer_id' = v_cust->>'customer_id' limit 1;
        if v_option is null then
          v_blockers := v_blockers || integration.legacy_sync_issue('REWASH_CUSTOMER_NOT_ELIGIBLE',
            coalesce(v_cust->>'customer_code', integration.legacy_sync_text(v_line,'CustomerID'))||' is not an active customer.');
        else
          v_included := true;
          v_parts := v_parts || jsonb_build_array(jsonb_build_object(
            'source_line_id', v_line_id, 'customer_id', v_cust->>'customer_id',
            'customer_code', v_option->>'customer_code', 'customer_name', v_option->>'customer_name',
            'service_codes', coalesce(v_option->'service_codes','[]'::jsonb),
            'scheduled_days', coalesce(v_option->'scheduled_days','[]'::jsonb),
            'batch_reference', v_line_batch, 'quantity_kg', v_line_kg,
            'line_no', integration.legacy_sync_parse_number(integration.legacy_sync_text(v_line,'LineNo'))));
        end if;
      end if;
    end if;
    v_source_lines := v_source_lines || jsonb_build_array(jsonb_build_object(
      'source_line_id', v_line_id, 'fingerprint', integration.legacy_sync_fingerprint(v_line),
      'included', v_included, 'customer_id', v_cust->>'customer_id', 'payload', v_line));
  end loop;

  -- One KG line per customer, in legacy line order.
  select coalesce(jsonb_agg(x order by x->>'first_line_no_sort', x->>'customer_code'), '[]'::jsonb) into v_lines
  from (
    select jsonb_build_object(
      'customer_id', p->>'customer_id',
      'customer_code', min(p->>'customer_code'),
      'customer_name', min(p->>'customer_name'),
      'service_codes', (array_agg(p->'service_codes'))[1],
      'scheduled_days', (array_agg(p->'scheduled_days'))[1],
      'batch_reference', nullif(string_agg(distinct p->>'batch_reference', ', '), ''),
      'quantity_kg', sum((p->>'quantity_kg')::numeric),
      'source_line_ids', jsonb_agg(p->>'source_line_id' order by p->>'source_line_id'),
      'first_line_no_sort', lpad(coalesce(min((p->>'line_no')::numeric)::text,'999999'), 9, '0')) as x
    from jsonb_array_elements(v_parts) p
    group by p->>'customer_id'
  ) a;
  select coalesce(jsonb_agg((l - 'first_line_no_sort') || jsonb_build_object('line_no', n) order by n), '[]'::jsonb)
  into v_lines
  from jsonb_array_elements(v_lines) with ordinality t(l, n);

  select coalesce(sum((l->>'quantity_kg')::numeric),0) into v_total from jsonb_array_elements(v_lines) l;
  if exists (select 1 from jsonb_array_elements(v_lines) l where length(l->>'batch_reference') > 120) then
    v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_TOO_LONG','Summed customer batches exceed 120 characters.');
  end if;
  if exists (select 1 from jsonb_array_elements(v_lines) l where (l->>'quantity_kg')::numeric > 10000) then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY','A customer total exceeds 10000 kg.');
  end if;

  v_header_kg := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_entry,'QtyKg'));
  if v_header_kg is not null and abs(v_header_kg - v_total) > 0.005 then
    v_warnings := v_warnings || integration.legacy_sync_issue('HEADER_TOTAL_DIFFERS',
      format('Header %s kg, lines %s kg', v_header_kg, v_total));
  end if;

  if jsonb_array_length(v_lines) = 0 then
    if v_target.finish_rewash_entry_id is not null then
      v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_QUANTITY_REMOVED',
        'The legacy cell now has no ReWash kg, but V2 already has this cell.');
    else
      v_no_quantity := true;
    end if;
  end if;

  -- Batch references: as in record_finish_rewash_v1, free among the day's other ACTIVE records.
  if v_business is not null and exists (
       select 1 from jsonb_array_elements(v_parts) p
       where p->>'batch_reference' is not null and (
         exists (select 1 from public.finish_production_entries e
                 join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
                 where e.status='ACTIVE' and e.production_business_date=v_business
                   and lower(l.batch_reference)=lower(p->>'batch_reference'))
         or exists (select 1 from public.finish_rewash_entries e
                    join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
                    where e.status='ACTIVE' and e.production_business_date=v_business
                      and e.entry_group_id is distinct from v_target_group
                      and lower(coalesce(l.batch_reference,''))=lower(p->>'batch_reference')))) then
    v_blockers := v_blockers || integration.legacy_sync_issue('BATCH_REFERENCE_IN_USE',
      'A ReWash line batch is already used by another ACTIVE Finish record of the day.');
  end if;

  if v_target.finish_rewash_entry_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('c', (l->>'customer_id')::uuid, 'b', upper(l->>'batch_reference'),
                                                 'q', trim_scale((l->>'quantity_kg')::numeric))
                              order by (l->>'customer_id')::uuid, (l->>'quantity_kg')::numeric), '[]'::jsonb)
           = integration.legacy_sync_rewash_entry_lines(v_target.finish_rewash_entry_id)
    into v_same
    from jsonb_array_elements(v_lines) l;
    v_same := v_same and (v_staff->>'staff_id' is null
                          or (v_staff->>'staff_id')::uuid is not distinct from v_target.processed_by_staff_id);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    v_outcome := 'BLOCKED';
  elsif v_no_quantity then
    v_outcome := 'PENDING_SOURCE';
  elsif v_target.finish_rewash_entry_id is null then
    v_outcome := 'READY'; v_action := 'CREATE';
  elsif v_target_via = 'LINK' and v_same then
    v_outcome := 'ALREADY_IMPORTED';
  elsif v_target_via = 'LINK' then
    v_outcome := 'READY'; v_action := 'UPDATE';
  elsif v_same then
    v_outcome := 'READY'; v_action := 'ADOPT';
  else
    v_outcome := 'READY'; v_action := 'ADOPT_AND_UPDATE';
  end if;

  return jsonb_build_object(
    'outcome', v_outcome,
    'action', v_action,
    'source_record_id', v_id,
    'fingerprint', v_fp,
    'blockers', v_blockers,
    'warnings', v_warnings,
    'target', case when v_target_group is not null then jsonb_build_object(
      'via', v_target_via,
      'entry_group_id', v_target_group,
      'finish_rewash_entry_id', v_target.finish_rewash_entry_id,
      'revision_no', v_target.revision_no,
      'lines', case when v_target.finish_rewash_entry_id is not null
                    then integration.legacy_sync_rewash_entry_lines(v_target.finish_rewash_entry_id) end,
      'processed_by_staff_id', v_target.processed_by_staff_id) end,
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
      'processed_by_staff_id', v_staff->>'staff_id',
      'processed_by_name', coalesce(v_staff->>'name', 'Legacy Finish (Apps Script)'),
      'processed_by_resolution', v_staff->>'resolution'),
    'lines', v_lines,
    'source_lines', v_source_lines,
    'totals', jsonb_build_object('kg', v_total, 'customers', jsonb_array_length(v_lines),
                                 'source_lines', jsonb_array_length(v_source_lines)));
end;
$$;

create or replace function integration.legacy_sync_rewash_dry_run(p_records jsonb)
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
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 40 then
    raise exception using errcode='22023', message='Send between 1 and 40 legacy HOUSEHOLD headers.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_rewash_cell(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    v_extra := '[]'::jsonb;
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id') > 1 then
      v_extra := v_extra || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH');
    end if;
    if v_plan#>>'{resolved,cell_key}' is not null and v_plan->>'outcome' in ('READY','BLOCKED','PENDING_SOURCE') and (
        select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' is distinct from v_plan->>'source_record_id'
          and o->>'outcome' in ('READY','BLOCKED','PENDING_SOURCE','ALREADY_IMPORTED')
          and o#>>'{resolved,cell_key}' = v_plan#>>'{resolved,cell_key}') > 0 then
      v_extra := v_extra || integration.legacy_sync_issue('CELL_SHARED_IN_BATCH',
        'Two legacy HOUSEHOLD headers name the same date, shift and table.');
    end if;
    if jsonb_array_length(v_extra) > 0 and v_plan->>'outcome' in ('READY','BLOCKED','PENDING_SOURCE') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || v_extra);
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
  end loop;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'actions', (select coalesce(jsonb_object_agg(a, n),'{}'::jsonb) from (
        select o->>'action' as a, count(*) as n from jsonb_array_elements(v_out) o
        where o->>'outcome'='READY' group by 1) x),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'pending_source', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='PENDING_SOURCE'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'skipped', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='SKIPPED'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'ready_kg', (select coalesce(sum((o#>>'{totals,kg}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'plans', v_out);
end;
$$;

-- One HOUSEHOLD header (one ReWash cell) per call, one transaction.
create or replace function integration.legacy_sync_import_rewash_cell(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'FINISH_AREA';
  c_table constant text := 'FinishEntries';
  c_line_table constant text := 'RewashProduction';
  c_source constant text := 'LEGACY_SYNC_FINISH';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_plan jsonb;
  v_r jsonb;
  v_src jsonb;
  v_done integer;
  v_action text;
  v_old public.finish_rewash_entries%rowtype;
  v_new public.finish_rewash_entries%rowtype;
  v_entry_id uuid := gen_random_uuid();
  v_line jsonb;
  v_line_id uuid;
  v_note text;
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

  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_FINISH:'||v_id, 0));
  -- Plan once to find the cell, lock the cell, then plan again under the lock.
  v_plan := integration.legacy_sync_plan_rewash_cell(p_record);
  if v_plan#>>'{resolved,cell_key}' is not null then
    perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_REWASH_CELL:'||(v_plan#>>'{resolved,cell_key}'), 0));
    v_plan := integration.legacy_sync_plan_rewash_cell(p_record);
  end if;

  perform integration.legacy_sync_keep_version(c_system, c_table, v_id, v_plan->>'fingerprint', p_record->'entry', p_sync_run_id);
  for v_src in select value from jsonb_array_elements(coalesce(v_plan->'source_lines','[]'::jsonb)) loop
    perform integration.legacy_sync_keep_version(c_system, c_line_table, v_src->>'source_line_id',
      v_src->>'fingerprint', v_src->'payload', p_sync_run_id);
  end loop;

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(c_system, c_table, v_plan - 'source_lines', p_record, p_sync_run_id);
    return v_plan - 'source_lines';
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_REWASH','UPDATE_LEGACY_REWASH','ADOPT_LEGACY_REWASH');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_r := v_plan->'resolved';
  v_action := v_plan->>'action';
  v_note := 'Legacy Finish sync; source group FINISH:'||v_id;

  if v_action in ('UPDATE','ADOPT','ADOPT_AND_UPDATE') then
    select * into v_old from public.finish_rewash_entries e
    where e.finish_rewash_entry_id=(v_plan#>>'{target,finish_rewash_entry_id}')::uuid
    for update;
    if not found or v_old.status <> 'ACTIVE' then
      raise exception using errcode='40001', message='The V2 ReWash entry changed during import. Retry.';
    end if;
  end if;

  if v_action in ('ADOPT','ADOPT_AND_UPDATE') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'HOUSEHOLD_TO_REWASH_ENTRY', 'public.finish_rewash_entries', v_old.finish_rewash_entry_id,
      v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted', true, 'revision_no', v_old.revision_no, 'warnings', v_plan->'warnings'));

    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    select c_system, c_line_table, s->>'source_line_id', 'REWASH_LINE_TO_LINE', 'public.finish_rewash_lines',
      l.finish_rewash_line_id, s->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted', true, 'household_entry_id', v_id)
    from jsonb_array_elements(v_plan->'source_lines') s
    join public.finish_rewash_lines l
      on l.finish_rewash_entry_id=v_old.finish_rewash_entry_id and l.customer_id=(s->>'customer_id')::uuid
    where (s->>'included')::boolean;

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data,
      reason, source_application, correlation_id)
    values (null, null, 'ADOPT_LEGACY_REWASH', 'finish_rewash_entries', v_old.finish_rewash_entry_id::text,
      jsonb_build_object('plan', v_plan - 'source_lines'), 'Legacy ReWash sync: cell already in V2 from an earlier import',
      c_source, p_sync_run_id);

    if v_action = 'ADOPT' then
      return (v_plan - 'source_lines') || jsonb_build_object('outcome','ADOPTED','finish_rewash_entry_id',v_old.finish_rewash_entry_id);
    end if;
  end if;

  if v_old.finish_rewash_entry_id is not null then
    update public.finish_rewash_entries set status='SUPERSEDED'
    where finish_rewash_entry_id=v_old.finish_rewash_entry_id;
  end if;

  -- The partial unique index finish_rewash_one_active_cell_uq still guards a
  -- concurrent V2 save of the same cell: this insert then fails and rolls back.
  insert into public.finish_rewash_entries(
    finish_rewash_entry_id, entry_group_id, revision_no, status, supersedes_finish_rewash_entry_id,
    production_business_date, shift_id, shift_code_snapshot, station_id, table_code_snapshot, table_name_snapshot,
    processed_by_staff_id, processed_by_name_snapshot, notes, recorded_at, recorded_by_staff_id, recorded_by_auth_user_id)
  values (
    v_entry_id, coalesce(v_old.entry_group_id, v_entry_id), coalesce(v_old.revision_no, 0) + 1, 'ACTIVE',
    v_old.finish_rewash_entry_id,
    (v_r->>'production_business_date')::date, (v_r->>'shift_id')::uuid, v_r->>'shift_code',
    (v_r->>'station_id')::uuid, v_r->>'table_code', v_r->>'table_name',
    coalesce(nullif(v_r->>'processed_by_staff_id','')::uuid, v_old.processed_by_staff_id),
    case when v_r->>'processed_by_staff_id' is null and v_old.finish_rewash_entry_id is not null
         then v_old.processed_by_name_snapshot else v_r->>'processed_by_name' end,
    v_note,
    case when v_old.finish_rewash_entry_id is null then coalesce((v_r->>'recorded_at')::timestamptz, now()) else now() end,
    null, null)
  returning * into v_new;

  for v_line in select value from jsonb_array_elements(v_plan->'lines') loop
    insert into public.finish_rewash_lines(finish_rewash_entry_id, line_no, customer_id, customer_code_snapshot,
      customer_name_snapshot, service_codes_snapshot, scheduled_days_snapshot, batch_reference, quantity_kg)
    values (v_entry_id, (v_line->>'line_no')::integer, (v_line->>'customer_id')::uuid, v_line->>'customer_code',
      v_line->>'customer_name',
      array(select jsonb_array_elements_text(coalesce(v_line->'service_codes','[]'::jsonb))),
      array(select jsonb_array_elements_text(coalesce(v_line->'scheduled_days','[]'::jsonb))),
      v_line->>'batch_reference', (v_line->>'quantity_kg')::numeric)
    returning finish_rewash_line_id into v_line_id;

    if v_action = 'CREATE' then
      insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
        target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
      select c_system, c_line_table, s->>'source_line_id', 'REWASH_LINE_TO_LINE', 'public.finish_rewash_lines',
        v_line_id, s->>'fingerprint', p_sync_run_id,
        jsonb_build_object('household_entry_id', v_id, 'finish_rewash_entry_id', v_entry_id,
          'summed_with', v_line->'source_line_ids')
      from jsonb_array_elements(v_plan->'source_lines') s
      where (s->>'included')::boolean and s->>'customer_id' = v_line->>'customer_id';
    end if;
  end loop;

  if v_action = 'CREATE' then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'HOUSEHOLD_TO_REWASH_ENTRY', 'public.finish_rewash_entries', v_entry_id,
      v_plan->>'fingerprint', p_sync_run_id, jsonb_build_object('warnings', v_plan->'warnings'));
  end if;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data,
    reason, source_application, correlation_id)
  values (null, null,
    case when v_action='CREATE' then 'IMPORT_LEGACY_REWASH' else 'UPDATE_LEGACY_REWASH' end,
    'finish_rewash_entries', v_entry_id::text,
    case when v_old.finish_rewash_entry_id is not null
         then jsonb_build_object('entry', to_jsonb(v_old), 'lines', v_plan#>'{target,lines}') end,
    jsonb_build_object('entry', to_jsonb(v_new), 'plan', v_plan - 'source_lines'),
    'Legacy HOUSEHOLD imported as ReWash (owner decision 2026-10-27)', c_source, p_sync_run_id);

  return (v_plan - 'source_lines') || jsonb_build_object(
    'outcome', case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' else 'ADOPTED_AND_UPDATED' end,
    'finish_rewash_entry_id', v_entry_id,
    'supersedes_finish_rewash_entry_id', v_old.finish_rewash_entry_id,
    'revision_no', v_new.revision_no);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Privileges: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_finish_window_start() from public, anon, authenticated;
revoke all on function integration.legacy_sync_notes_reference(text,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_resolve_staff(text,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_finish_entry_lines(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_lines_key(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_finish_entry(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_finish_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_keep_version(text,text,text,text,jsonb,uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_hold_for_review(text,text,jsonb,jsonb,uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_finish_entry(uuid,jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_rewash_entry_lines(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_rewash_cell(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_rewash_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_rewash_cell(uuid,jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_plan_finish_entry(jsonb) to service_role;
grant execute on function integration.legacy_sync_finish_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_finish_entry(uuid,jsonb) to service_role;
grant execute on function integration.legacy_sync_plan_rewash_cell(jsonb) to service_role;
grant execute on function integration.legacy_sync_rewash_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_rewash_cell(uuid,jsonb) to service_role;

comment on function integration.legacy_sync_plan_finish_entry(jsonb) is
  'Read-only plan for one legacy Finish entry: READY with action CREATE, UPDATE, ADOPT or ADOPT_AND_UPDATE, ALREADY_IMPORTED, PENDING_SOURCE, SKIPPED, REWASH_ROUTE or BLOCKED.';
comment on function integration.legacy_sync_import_finish_entry(uuid,jsonb) is
  'Imports or updates one legacy Finish entry inside an open COMMIT run, when FINISH_HISTORICAL_IMPORT is enabled. Updates are new revisions. service_role only.';
comment on function integration.legacy_sync_plan_rewash_cell(jsonb) is
  'Read-only plan for one legacy HOUSEHOLD header with its RewashProduction lines as one V2 ReWash cell.';
comment on function integration.legacy_sync_rewash_dry_run(jsonb) is
  'Read-only dry run for up to 40 legacy HOUSEHOLD headers. Writes nothing.';
comment on function integration.legacy_sync_import_rewash_cell(uuid,jsonb) is
  'Imports or updates one legacy ReWash cell inside an open COMMIT run, when FINISH_REWASH_HISTORICAL_IMPORT is enabled. Updates are new revisions. service_role only.';
update integration.legacy_sync_settings
set note = 'Seeded disabled. Legacy HOUSEHOLD headers with RewashProduction lines as ReWash. The limit counts ReWash writes (create, update, adopt) per run.',
    changed_at = now(), changed_by = 'migration 202610270003'
where setting_key = 'FINISH_REWASH_HISTORICAL_IMPORT' and not enabled;
update integration.legacy_sync_settings
set note = 'Seeded disabled. The limit counts Finish writes (create, update, adopt) per run.',
    changed_at = now(), changed_by = 'migration 202610270003'
where setting_key = 'FINISH_HISTORICAL_IMPORT' and not enabled;

commit;
