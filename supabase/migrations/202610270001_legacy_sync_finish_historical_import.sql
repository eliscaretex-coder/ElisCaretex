-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270001_legacy_sync_finish_historical_import
--
-- Historical import of legacy Finish Area entries (Apps Script sheet
-- FinishEntries, linked to CentralDB WashItems) into Finish V2.
-- Depends on 202610260002_legacy_sync_identity_foundation.
--
-- Why a separate path: the live Finish RPCs (record_finish_production and
-- its v2/v3/terminal wrappers) derive the business date, shift, roster,
-- staff and edit cutoff from now(), require an authenticated Finish
-- account, require V2 washing evidence and change current trolley custody.
-- None of that can describe a past legacy entry, so this path:
--   * never calls the live Finish RPCs and never touches trolley, custody or
--     Sorting tables (legacy trolley codes are kept as evidence only);
--   * resolves the Production Flow by its canonical key
--     (customer + CLOTHES + scheduled date) through ensure_production_flow_item;
--   * writes entry + lines + one FINISH_PRODUCTION_RECORDED flow event +
--     audit_log + insert-only legacy links, all with
--     source_application = 'LEGACY_SYNC_FINISH';
--   * holds anything ambiguous in integration.legacy_sync_review_items.
--
-- Safety gates (all must pass before a single row is written):
--   1. integration.legacy_sync_settings 'FINISH_HISTORICAL_IMPORT' is enabled
--      (seeded DISABLED; only the owner enables it, through SQL);
--   2. the call names a COMMIT run that is CREATED or RUNNING;
--   3. the run has not reached max_entries_per_run (seeded 3 for the pilot);
--   4. the planner returns READY (no blockers).
-- The dry run (legacy_sync_finish_dry_run) is a STABLE read-only function:
-- it cannot write anything, not even a review item or a record version.
--
-- Finish trigger: finish_enforce_new_entry_current_shift is replaced with
-- its live body (202610230005) plus one narrow branch. A LEGACY_SYNC_FINISH
-- row passes only when the importer registered that exact entry id for the
-- current transaction in a private table no client can reach. Any other
-- row labelled LEGACY_SYNC_FINISH is rejected. Live behaviour and the
-- 2026-10-23 Apps Script exception are unchanged.
--
-- Access: every function here is revoked from public, anon and
-- authenticated; the entry points are executable by service_role only
-- (the legacy-sync Edge Function). Apps Script never holds a Supabase key.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Settings: master write switch and pilot limit
-- ---------------------------------------------------------------------
create table if not exists integration.legacy_sync_settings (
  setting_key text primary key,
  enabled boolean not null default false,
  max_entries_per_run integer not null default 3,
  changed_at timestamptz not null default now(),
  changed_by text not null,
  note text,
  constraint legacy_sync_settings_limit_check
    check (max_entries_per_run between 1 and 500)
);

insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('FINISH_HISTORICAL_IMPORT', false, 3, 'migration 202610270001',
        'Seeded disabled. The owner enables it for an approved pilot only.')
on conflict (setting_key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Owner-approved legacy value maps (shift, table, status, product)
--    A raw value that already equals a canonical code is accepted for
--    SHIFT, FINISH_TABLE and WASH_ITEM_TYPE. Everything else, and every
--    FINISH_STATUS value, needs an approved map row. Insert-only; a row can
--    only be retired, once.
-- ---------------------------------------------------------------------
create table if not exists integration.legacy_sync_value_maps (
  map_id uuid primary key default gen_random_uuid(),
  source_system text not null,
  value_domain text not null
    check (value_domain in ('SHIFT','FINISH_TABLE','FINISH_STATUS','WASH_ITEM_TYPE')),
  raw_value text not null,
  raw_value_key text generated always as (upper(regexp_replace(btrim(raw_value), '\s+', ' ', 'g'))) stored,
  canonical_value text not null,
  approved_by text not null check (length(btrim(approved_by)) > 0),
  approved_at timestamptz not null default now(),
  retired_at timestamptz,
  retired_by text,
  note text,
  constraint legacy_sync_value_maps_canonical_check check (
    (value_domain='SHIFT' and canonical_value in ('MORNING','EVENING'))
    or (value_domain='FINISH_TABLE' and canonical_value in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3'))
    or (value_domain='FINISH_STATUS' and canonical_value in ('ACTIVE','NOT_IMPORTED'))
    or (value_domain='WASH_ITEM_TYPE' and canonical_value in ('CLOTHES','MOP','NOT_IMPORTED'))
  ),
  constraint legacy_sync_value_maps_retired_check
    check ((retired_at is null and retired_by is null) or (retired_at is not null and retired_by is not null))
);

create unique index if not exists legacy_sync_value_maps_active_uidx
  on integration.legacy_sync_value_maps (source_system, value_domain, raw_value_key)
  where retired_at is null;

create or replace function integration.legacy_sync_value_map_guard()
returns trigger
language plpgsql
set search_path = integration, pg_temp
as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000', message='Legacy value maps cannot be deleted. Retire the row instead.';
  end if;
  if old.retired_at is not null then
    raise exception using errcode='55000', message='A retired legacy value map cannot change.';
  end if;
  if (new.map_id, new.source_system, new.value_domain, new.raw_value, new.canonical_value,
      new.approved_by, new.approved_at, new.note)
     is distinct from
     (old.map_id, old.source_system, old.value_domain, old.raw_value, old.canonical_value,
      old.approved_by, old.approved_at, old.note) then
    raise exception using errcode='55000', message='Only retirement can change a legacy value map.';
  end if;
  return new;
end;
$$;

drop trigger if exists legacy_sync_value_maps_guard on integration.legacy_sync_value_maps;
create trigger legacy_sync_value_maps_guard
  before update or delete on integration.legacy_sync_value_maps
  for each row execute function integration.legacy_sync_value_map_guard();

-- ---------------------------------------------------------------------
-- 3. Private per-transaction permit for the Finish trigger
-- ---------------------------------------------------------------------
create table if not exists integration.legacy_sync_finish_insert_permits (
  transaction_id xid8 not null,
  finish_production_entry_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (transaction_id, finish_production_entry_id)
);

alter table integration.legacy_sync_settings enable row level security;
alter table integration.legacy_sync_value_maps enable row level security;
alter table integration.legacy_sync_finish_insert_permits enable row level security;

revoke all on integration.legacy_sync_settings from public, anon, authenticated;
revoke all on integration.legacy_sync_value_maps from public, anon, authenticated;
revoke all on integration.legacy_sync_finish_insert_permits from public, anon, authenticated;
revoke all on function integration.legacy_sync_value_map_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Finish trigger: live body (202610230005) + narrow legacy-sync branch
-- ---------------------------------------------------------------------
create or replace function public.finish_enforce_new_entry_current_shift()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare v_auto jsonb; v_expected_shift text;
begin
  -- Legacy sync historical import: allowed only for the exact entry the
  -- importer registered in this transaction. The label alone is refused.
  if new.source_application = 'LEGACY_SYNC_FINISH' then
    if auth.uid() is null
       and coalesce(new.revision_no,1) = 1
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
-- 5. Small pure helpers
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_text(p_object jsonb, p_key text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(btrim(p_object->>p_key), '');
$$;

create or replace function integration.legacy_sync_issue(p_code text, p_detail text default null)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('code', p_code, 'detail', p_detail)));
$$;

-- Decimal point only. A comma is ambiguous (1,234) and is refused.
create or replace function integration.legacy_sync_parse_number(p_value text)
returns numeric
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case when btrim(p_value) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(p_value)::numeric end;
$$;

create or replace function integration.legacy_sync_parse_date(p_value text)
returns date
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
begin
  if p_value is null or btrim(p_value) !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    return null;
  end if;
  return btrim(p_value)::date;
exception when others then
  return null;
end;
$$;

-- ISO 8601 with Z/offset is taken as given. Without offset it is Dublin local time.
create or replace function integration.legacy_sync_parse_instant(p_value text)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, pg_temp
as $$
declare v text := btrim(coalesce(p_value,''));
begin
  if v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
    return v::timestamptz;
  elsif v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?$' then
    return (replace(v,'T',' ')::timestamp) at time zone 'Europe/Dublin';
  end if;
  return null;
exception when others then
  return null;
end;
$$;

create or replace function integration.legacy_sync_fingerprint(p_value jsonb)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select 'sha256:' || encode(sha256(convert_to(coalesce(p_value,'null'::jsonb)::text, 'UTF8')), 'hex');
$$;

create or replace function integration.legacy_sync_map_value(
  p_source_system text,
  p_domain text,
  p_raw text
)
returns text
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select coalesce(
    (select m.canonical_value
     from integration.legacy_sync_value_maps m
     where m.source_system = p_source_system
       and m.value_domain = p_domain
       and m.retired_at is null
       and m.raw_value_key = upper(regexp_replace(btrim(p_raw), '\s+', ' ', 'g'))),
    case
      when p_domain='SHIFT' and upper(btrim(p_raw)) in ('MORNING','EVENING') then upper(btrim(p_raw))
      when p_domain='FINISH_TABLE' and upper(btrim(p_raw)) in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then upper(btrim(p_raw))
      when p_domain='WASH_ITEM_TYPE' and upper(btrim(p_raw)) in ('CLOTHES','MOP') then upper(btrim(p_raw))
    end
  );
$$;

-- ---------------------------------------------------------------------
-- 6. Planner: resolves and validates one legacy Finish entry. Read-only.
--
-- p_record:
-- {
--   "source_record_id": "<FinishEntries.EntryID>",
--   "entry":     { FinishEntries row: EntryID, CreatedAt, BusinessDate, Shift,
--                  TableID, EntryType, WashItemID, WashID, CustomerID,
--                  CustomerName, Trolleys, BatchNo, QtyKg, QtyUnits, TotalKg,
--                  Status, Notes, optional StaffUserID / StaffName },
--   "wash_item": { CentralDB WashItems row: WashItemID, WashID, CustomerID,
--                  CustomerName, ScheduledDate, Type, ... } or null
-- }
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

  -- Entry type: only NORMAL has an approved V2 path.
  v_entry_type := upper(integration.legacy_sync_text(v_entry,'EntryType'));
  if v_entry_type = 'HOUSEHOLD' then
    v_blockers := v_blockers || integration.legacy_sync_issue('HOUSEHOLD_PENDING_DECISION');
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
    v_blockers := v_blockers || integration.legacy_sync_issue('SUNDAY_PRODUCTION_REVIEW', v_business::text);
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
-- 7. Dry run: plans up to 60 records and adds batch-level checks.
--    STABLE: it cannot write anything.
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
-- 8. Runs
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_start_run(
  p_source_system text,
  p_mode text,
  p_date_from date,
  p_date_to date,
  p_requested_by text
)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare v_run uuid;
begin
  if nullif(btrim(p_requested_by),'') is null then
    raise exception using errcode='22023', message='requested_by is required.';
  end if;
  insert into integration.legacy_sync_runs(source_system, mode, date_from, date_to, requested_by, status)
  values (btrim(p_source_system), upper(btrim(p_mode)), p_date_from, p_date_to, btrim(p_requested_by), 'RUNNING')
  returning sync_run_id into v_run;
  return v_run;
end;
$$;

create or replace function integration.legacy_sync_finish_run(
  p_sync_run_id uuid,
  p_status text,
  p_summary jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  if upper(p_status) not in ('COMPLETED','FAILED','CANCELLED') then
    raise exception using errcode='22023', message='A run can only finish as COMPLETED, FAILED or CANCELLED.';
  end if;
  update integration.legacy_sync_runs
  set status=upper(p_status), summary=coalesce(p_summary,'{}'::jsonb), finished_at=now()
  where sync_run_id=p_sync_run_id and status in ('CREATED','RUNNING');
  if not found then
    raise exception using errcode='P0002', message='Open legacy sync run not found.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Importer: one legacy Finish entry, one transaction.
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
  v_entry_id uuid := gen_random_uuid();
  v_line jsonb;
  v_line_id uuid;
  v_event_id uuid;
  v_blocker jsonb;
  v_done integer;
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

  select count(*) into v_done from integration.legacy_sync_record_links l
  where l.sync_run_id=p_sync_run_id and l.link_role='FINISH_ENTRY_TO_ENTRY';
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_plan := integration.legacy_sync_plan_finish_entry(p_record);

  -- Keep every distinct source version (insert-only, idempotent).
  if v_plan->>'fingerprint' is not null then
    insert into integration.legacy_sync_record_versions(source_system, source_table, source_record_id,
      source_fingerprint, payload, first_seen_run)
    values (c_system, c_table, v_id, v_plan->>'fingerprint', p_record->'entry', p_sync_run_id)
    on conflict on constraint legacy_sync_record_versions_uq do nothing;
  end if;
  if v_plan->>'wash_item_fingerprint' is not null and v_plan#>>'{resolved,wash_item_id}' is not null then
    insert into integration.legacy_sync_record_versions(source_system, source_table, source_record_id,
      source_fingerprint, payload, first_seen_run)
    values (c_wash_system, c_wash_table, v_plan#>>'{resolved,wash_item_id}', v_plan->>'wash_item_fingerprint',
      p_record->'wash_item', p_sync_run_id)
    on conflict on constraint legacy_sync_record_versions_uq do nothing;
  end if;

  if v_plan->>'outcome' = 'ALREADY_IMPORTED' then
    return v_plan;
  end if;

  if v_plan->>'outcome' <> 'READY' then
    for v_blocker in select value from jsonb_array_elements(coalesce(v_plan->'blockers','[]'::jsonb)) loop
      insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id,
        reason_code, raw, sync_run_id)
      values (c_system, c_table, v_id, v_blocker->>'code',
        jsonb_build_object('record', p_record, 'detail', v_blocker->>'detail', 'fingerprint', v_plan->>'fingerprint'),
        p_sync_run_id)
      on conflict (source_system, source_table, source_record_id, reason_code) where status='OPEN' do nothing;
    end loop;
    return v_plan;
  end if;

  v_r := v_plan->'resolved';

  -- Serialize writers of the same flow key, then resolve or create the flow.
  perform pg_advisory_xact_lock(hashtextextended(
    'FLOW:'||(v_r->>'customer_id')||':CLOTHES:'||(v_r->>'scheduled_for_date'), 0));

  v_flow_id := public.ensure_production_flow_item(
    (v_r->>'customer_id')::uuid, 'CLOTHES', (v_r->>'scheduled_for_date')::date,
    (v_r->>'production_business_date')::date,
    nullif(v_r#>>'{schedule,schedule_version_id}','')::uuid,
    nullif(v_r#>>'{schedule,schedule_day_id}','')::uuid,
    nullif(v_r#>>'{schedule,schedule_product_id}','')::uuid,
    nullif(v_r#>>'{schedule,production_order}','')::integer,
    nullif(v_r#>>'{schedule,route_id}','')::uuid,
    v_r#>>'{schedule,route_code}', v_r#>>'{schedule,route_display_name}', v_r#>>'{schedule,route_color}');

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
               and e.shift_code_snapshot=v_r->>'shift_code' and e.table_code_snapshot=v_r->>'table_code') then
    raise exception using errcode='23505', message='The flow already has an ACTIVE Finish entry for this cell.';
  end if;
  if exists (select 1 from public.finish_production_entries e
             join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
             where e.status='ACTIVE' and lower(l.batch_reference)=lower(v_plan#>>'{lines,0,batch_reference}')
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

  -- Entry. The permit lets the Finish trigger accept exactly this row.
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
    integration.legacy_sync_text(p_record->'entry','Notes'), c_source, (v_r->>'recorded_at')::timestamptz,
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
    'Legacy Finish historical import', c_source, p_sync_run_id);

  return v_plan || jsonb_build_object(
    'outcome', 'IMPORTED',
    'finish_production_entry_id', v_entry_id,
    'production_flow_item_id', v_flow_id,
    'flow_event_id', v_event_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Privileges: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_text(jsonb,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_issue(text,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_parse_number(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_parse_date(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_parse_instant(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_fingerprint(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_map_value(text,text,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_finish_entry(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_finish_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_start_run(text,text,date,date,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_finish_run(uuid,text,jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_finish_entry(uuid,jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_finish_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_plan_finish_entry(jsonb) to service_role;
grant execute on function integration.legacy_sync_start_run(text,text,date,date,text) to service_role;
grant execute on function integration.legacy_sync_finish_run(uuid,text,jsonb) to service_role;
grant execute on function integration.legacy_sync_import_finish_entry(uuid,jsonb) to service_role;

comment on table integration.legacy_sync_settings is
  'Legacy sync switches. FINISH_HISTORICAL_IMPORT is seeded disabled with a pilot limit of 3 entries per run.';
comment on table integration.legacy_sync_value_maps is
  'Owner-approved legacy code values (shift, table, Finish status, WashItem type). Insert-only; rows are retired, never edited.';
comment on table integration.legacy_sync_finish_insert_permits is
  'Private per-transaction permit that lets finish_enforce_new_entry_current_shift accept one importer-written entry.';
comment on function integration.legacy_sync_plan_finish_entry(jsonb) is
  'Read-only plan for one legacy Finish entry: identity resolution, blockers, warnings, lines and flow action.';
comment on function integration.legacy_sync_finish_dry_run(jsonb) is
  'Read-only dry run for up to 60 legacy Finish entries, with batch-level duplicate and cell checks. Writes nothing.';
comment on function integration.legacy_sync_import_finish_entry(uuid,jsonb) is
  'Imports one READY legacy Finish entry inside an open COMMIT run, when FINISH_HISTORICAL_IMPORT is enabled. Blocked records go to review. service_role only.';

commit;
