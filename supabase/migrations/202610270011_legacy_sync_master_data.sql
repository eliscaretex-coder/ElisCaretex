-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270011_legacy_sync_master_data
--
-- Fifth part of the nightly legacy sync (owner decision 2026-10-27: the
-- registers are still edited in the legacy CentralDB, so they are synced
-- too): people, customers, trolleys, drivers and vehicles.
--
-- One kind "master" with five record types, one per CentralDB sheet row:
--   * STAFF    User         (key UserID)      -> public.staff_members (+ cover roles)
--   * CUSTOMER CustomerMaster (key CustomerID) -> public.customers (+ product services)
--   * TROLLEY  Trolley      (key TrolleyID)   -> public.trolleys (+ trolley events)
--   * DRIVER   Driver       (key DriverID)    -> public.distribution_drivers
--   * VEHICLE  Vehicles     (key Plate)       -> public.fleet_vehicles
--
-- Rules (owner decision 2026-10-27, "starting point + list"):
--   * a legacy row with no V2 record creates it, as if typed in V2;
--   * the first time a legacy row meets an existing V2 record it is only
--     linked (ADOPT). Values that differ today are NOT changed: they are
--     listed as warning V2_DIFFERS for the owner to settle once;
--   * from then on, each field the legacy app changes is written to V2 (the
--     legacy value wins for that field). Fields the legacy app did not change
--     keep any value edited in V2;
--   * the values last synced are kept append-only in
--     integration.legacy_sync_master_states (links stay insert-only);
--   * a person found by name with no legacy id gets the legacy id (ADOPT);
--   * deactivation and reactivation follow the V2 screens: a customer
--     deactivated ends its product services and supersedes its schedules;
--     a trolley out of service keeps the status to return to; a trolley
--     at a customer cannot be put out of service or retired (review);
--   * a record deleted in V2 is left alone (SKIPPED).
--
-- The import accepts one record or a batch {"records":[...]} of up to 60:
-- each record runs in its own subtransaction, so one failure does not undo
-- the others. Only writes to V2 count toward the run limit.
--
-- New switch MASTER_DATA_IMPORT (seeded OFF, limit 300). The Apps Script
-- control ON/OFF switches it with the others.
-- Apply after 202610270007-0010: it recreates the provenance checks and the
-- dispatchers with every part.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch, provenance roles and last-synced values
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('MASTER_DATA_IMPORT', false, 300, 'migration 202610270011',
        'Seeded disabled. Turned on with the other imports from the Apps Script page.')
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
     'STAFF_MASTER','CUSTOMER_MASTER','TROLLEY_MASTER','DRIVER_MASTER','VEHICLE_MASTER')),
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
    (link_role='VEHICLE_MASTER' and target_table='public.fleet_vehicles')
  );

create table if not exists integration.legacy_sync_master_states (
  state_id bigint generated always as identity primary key,
  source_system text not null,
  source_table text not null,
  source_record_id text not null,
  target_table text not null,
  target_id uuid not null,
  action text not null check (action in ('CREATE','ADOPT','ADOPT_BY_NAME','UPDATE','RELINK')),
  synced jsonb not null,
  source_fingerprint text not null,
  sync_run_id uuid references integration.legacy_sync_runs(sync_run_id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists legacy_sync_master_states_source_idx
  on integration.legacy_sync_master_states (source_system, source_table, source_record_id, state_id desc);

drop trigger if exists legacy_sync_master_states_insert_only on integration.legacy_sync_master_states;
create trigger legacy_sync_master_states_insert_only
  before update or delete on integration.legacy_sync_master_states
  for each row execute function integration.legacy_sync_block_mutation();

alter table integration.legacy_sync_master_states enable row level security;
revoke all on table integration.legacy_sync_master_states from public, anon, authenticated;

comment on table integration.legacy_sync_master_states is
  'Append-only: the register values last synced from each legacy CentralDB row. The latest row per source record is the baseline for the next sync.';

-- Columns that exist in the live database (added outside the tracked history
-- by the distribution imports). No-ops there; listed so this file is complete.
alter table public.distribution_drivers
  add column if not exists legacy_driver_id text,
  add column if not exists import_source text;

alter table public.fleet_vehicles
  add column if not exists legacy_status text,
  add column if not exists maintenance_start_on date,
  add column if not exists maintenance_end_on date,
  add column if not exists contract_type text,
  add column if not exists vehicle_description text,
  add column if not exists tachograph_type text,
  add column if not exists insurer_legacy_value text,
  add column if not exists make text,
  add column if not exists model_range text,
  add column if not exists tacho_calibration_due_on date,
  add column if not exists fuel_code text,
  add column if not exists contract_start_on date,
  add column if not exists contract_end_on date,
  add column if not exists body_detail text,
  add column if not exists tail_lift_detail_1 text,
  add column if not exists tail_lift_detail_2 text,
  add column if not exists monthly_rental_ex_vat numeric,
  add column if not exists contract_term_months integer,
  add column if not exists cvrt_last_on date,
  add column if not exists service_last_on date,
  add column if not exists tachograph_last_on date,
  add column if not exists tail_lift_weight_test_last_on date,
  add column if not exists tail_lift_weight_test_due_on date,
  add column if not exists registration_date date,
  add column if not exists tail_lift_loler_due_on date,
  add column if not exists tail_lift_loler_last_on date,
  add column if not exists legacy_registered_at timestamptz,
  add column if not exists legacy_updated_at timestamptz,
  add column if not exists import_source text;

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- Legacy Yes/No cells. Anything that is not a clear "yes" is false.
create or replace function integration.legacy_sync_yes(p_value text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select lower(btrim(coalesce(p_value,''))) in ('yes','y','true','1','sim');
$$;

-- Names compared without case and repeated spaces.
create or replace function integration.legacy_sync_name_key(p_value text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select nullif(lower(regexp_replace(btrim(coalesce(p_value,'')), '\s+', ' ', 'g')), '');
$$;

-- Record type -> legacy sheet, link role and V2 table.
create or replace function integration.legacy_sync_master_spec(p_type text)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case upper(coalesce(p_type,''))
    when 'STAFF' then jsonb_build_object('table','User','role','STAFF_MASTER','target','public.staff_members',
      'entity','staff_members','id_column','staff_id','id_field','UserID')
    when 'CUSTOMER' then jsonb_build_object('table','CustomerMaster','role','CUSTOMER_MASTER','target','public.customers',
      'entity','customers','id_column','customer_id','id_field','CustomerID')
    when 'TROLLEY' then jsonb_build_object('table','Trolley','role','TROLLEY_MASTER','target','public.trolleys',
      'entity','trolleys','id_column','trolley_id','id_field','TrolleyID')
    when 'DRIVER' then jsonb_build_object('table','Driver','role','DRIVER_MASTER','target','public.distribution_drivers',
      'entity','distribution_drivers','id_column','driver_id','id_field','DriverID')
    when 'VEHICLE' then jsonb_build_object('table','Vehicles','role','VEHICLE_MASTER','target','public.fleet_vehicles',
      'entity','fleet_vehicles','id_column','vehicle_id','id_field','Plate')
  end;
$$;

-- The V2 values a legacy row asks for, in V2 terms. Read-only.
-- Returns {"want": {...}, "blockers": [...], "warnings": [...]}.
create or replace function integration.legacy_sync_master_want(p_type text, p_row jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  t text := upper(coalesce(p_type,''));
  w jsonb := '{}'::jsonb;
  b jsonb := '[]'::jsonb;
  n jsonb := '[]'::jsonb;
  v text;
  m text[];
  v_active boolean;
  v_role text; v_area text; v_station text;
  v_status text;
  v_codes jsonb;
begin
  if t = 'STAFF' then
    v := regexp_replace(btrim(coalesce(integration.legacy_sync_text(p_row,'Name'),'')), '\s+', ' ', 'g');
    if v = '' then b := b || integration.legacy_sync_issue('MISSING_NAME'); end if;
    v_active := integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'Active'));
    w := w || jsonb_build_object('display_name', nullif(v,''), 'active', v_active,
      'joined_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'JoinedAt'),10)),
      'deactivated_on', case when not v_active
        then integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'DeactivatedAt'),10)) end,
      'roster_eligible', v_active and integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'Roster')),
      'fire_training', integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'FireTraining')),
      'first_aid_training', integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'FirstAidTraining')),
      'eod_capable', integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'EODCapable')));
    if (w->>'deactivated_on')::date < (w->>'joined_on')::date then
      b := b || integration.legacy_sync_issue('DEACTIVATED_BEFORE_JOINED', (w->>'joined_on')||' / '||(w->>'deactivated_on'));
    end if;

    v := upper(btrim(regexp_replace(coalesce(integration.legacy_sync_text(p_row,'Shift'),''), '\s*shift\s*$', '', 'i')));
    if not exists (select 1 from public.shifts s where s.shift_code=v and s.deleted_at is null) then
      b := b || integration.legacy_sync_issue('UNKNOWN_SHIFT', integration.legacy_sync_text(p_row,'Shift'));
    end if;
    w := w || jsonb_build_object('shift_code', nullif(v,''));

    v := lower(regexp_replace(btrim(coalesce(integration.legacy_sync_text(p_row,'Position'),'')), '\s+', ' ', 'g'));
    m := regexp_match(v, '^(general operative|team leader) - table ([123])$');
    if m is not null then
      v_role := case m[1] when 'team leader' then 'TEAM_LEADER' else 'GENERAL_OPERATIVE' end;
      v_area := 'FINISH'; v_station := 'FINISH_TABLE_' || m[2];
    elsif v = 'sorting area' then v_role := 'GENERAL_OPERATIVE'; v_area := 'SORTING'; v_station := 'SORTING_MAIN';
    elsif v in ('label','label operative') then v_role := 'LABEL'; v_area := 'FINISH'; v_station := 'FINISH_LABEL';
    elsif v = 'team leader' then v_role := 'TEAM_LEADER'; v_area := 'FINISH';
    elsif v = 'supervisor' then v_role := 'SUPERVISOR';
    elsif v = 'cleaner' then v_role := 'CLEANER';
    elsif v = 'support role' then v_role := 'SUPPORT_ROLE';
    elsif v = 'general operative' then v_role := 'GENERAL_OPERATIVE';
    elsif v = 'driver' then v_role := 'DRIVER'; v_area := 'DISTRIBUTION';
    else
      b := b || integration.legacy_sync_issue('UNKNOWN_POSITION', integration.legacy_sync_text(p_row,'Position'));
    end if;
    w := w || jsonb_build_object('role_code', v_role, 'area_code', v_area, 'station_code', v_station);

    -- Cover: comma list of role names; only roles V2 allows as cover are kept.
    select coalesce(jsonb_agg(distinct r.role_code order by r.role_code), '[]'::jsonb) into v_codes
    from regexp_split_to_table(coalesce(integration.legacy_sync_text(p_row,'Cover'),''), '\s*[,;/]\s*') tok
    join public.operational_roles r
      on lower(r.role_name) = lower(btrim(tok)) and r.allow_as_cover and r.active and r.deleted_at is null;
    w := w || jsonb_build_object('covers', v_codes);

  elsif t = 'CUSTOMER' then
    v := regexp_replace(btrim(coalesce(integration.legacy_sync_text(p_row,'CustomerName'),'')), '\s+', ' ', 'g');
    if v = '' then b := b || integration.legacy_sync_issue('MISSING_NAME'); end if;
    v_status := upper(coalesce(integration.legacy_sync_text(p_row,'ServiceType'),''));
    v_codes := case when v_status = '' then null else
      (select coalesce(jsonb_agg(c order by c), '[]'::jsonb)
       from unnest(array['CLOTHES','MOP']) c where v_status like '%' || c || '%') end;
    if v_codes = '[]'::jsonb then
      b := b || integration.legacy_sync_issue('UNKNOWN_SERVICE_TYPE', integration.legacy_sync_text(p_row,'ServiceType'));
    end if;
    w := w || jsonb_build_object('customer_name', nullif(v,''),
      'eircode', integration.legacy_sync_text(p_row,'Eircode'),
      'active', integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'Active')),
      'distribution_estimated_kg', integration.legacy_sync_parse_number(integration.legacy_sync_text(p_row,'KGEstimated')),
      'distribution_stop_count', round(integration.legacy_sync_parse_number(integration.legacy_sync_text(p_row,'Stops')))::integer,
      'notes', integration.legacy_sync_text(p_row,'Information'),
      'product_codes', v_codes,
      'legacy_service_type', integration.legacy_sync_text(p_row,'ServiceType'),
      'legacy_customer_type', integration.legacy_sync_text(p_row,'CustomerType'));
    if integration.legacy_sync_text(p_row,'KGEstimated') is not null and w->'distribution_estimated_kg' = 'null'::jsonb then
      b := b || integration.legacy_sync_issue('INVALID_KG', integration.legacy_sync_text(p_row,'KGEstimated'));
    end if;

  elsif t = 'TROLLEY' then
    v := upper(btrim(coalesce(integration.legacy_sync_text(p_row,'Type'),'')));
    if not exists (select 1 from public.trolley_types tt where tt.trolley_type_code=v and tt.active and tt.deleted_at is null) then
      b := b || integration.legacy_sync_issue('UNKNOWN_TROLLEY_TYPE', integration.legacy_sync_text(p_row,'Type'));
    end if;
    v_status := lower(btrim(coalesce(integration.legacy_sync_text(p_row,'Status'),'')));
    w := w || jsonb_build_object('trolley_type_code', nullif(v,''),
      'service_status', case when v_status like 'out of service%' then 'OUT_OF_SERVICE'
                             when v_status like 'retired%' then 'RETIRED' else 'IN_SERVICE' end,
      'notes', integration.legacy_sync_text(p_row,'Notes'),
      -- "_" keys are used when the record is created only, never compared.
      '_registered_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'RegisteredAt'),10)));

  elsif t = 'DRIVER' then
    v := regexp_replace(btrim(coalesce(integration.legacy_sync_text(p_row,'Name'),'')), '\s+', ' ', 'g');
    if v = '' then b := b || integration.legacy_sync_issue('MISSING_NAME'); end if;
    v_active := integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'Active'));
    select coalesce(jsonb_agg(distinct upper(c) order by upper(c)), '[]'::jsonb) into v_codes
    from regexp_split_to_table(coalesce(integration.legacy_sync_text(p_row,'LicenseType'),''), '[\s,;/+]+') c
    where btrim(c) <> '';
    w := w || jsonb_build_object('display_name', nullif(v,''), 'licence_categories', v_codes,
      'employment_status', case when v_active then 'ACTIVE' else 'INACTIVE' end,
      'joined_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'JoinedDate'),10)),
      'deactivated_on', case when not v_active
        then integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'DeactivatedDate'),10)) end,
      'roster_hidden', integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'RosterHidden')));

  elsif t = 'VEHICLE' then
    v := upper(btrim(coalesce(integration.legacy_sync_text(p_row,'Type'),'')));
    if v not in ('TRUCK','VAN','OTHER') then
      b := b || integration.legacy_sync_issue('UNKNOWN_VEHICLE_TYPE', integration.legacy_sync_text(p_row,'Type'));
    end if;
    v_status := lower(btrim(coalesce(integration.legacy_sync_text(p_row,'Status'),'')));
    v_active := integration.legacy_sync_yes(integration.legacy_sync_text(p_row,'Active'));
    if v_status not in ('available','maintenance','returned','off hire','sold','out of service','inactive') then
      b := b || integration.legacy_sync_issue('UNKNOWN_VEHICLE_STATUS', integration.legacy_sync_text(p_row,'Status'));
    end if;
    w := w || jsonb_build_object(
      'vehicle_type', nullif(v,''),
      'display_name', coalesce(integration.legacy_sync_text(p_row,'VehicleDescription'),
                               upper(regexp_replace(coalesce(integration.legacy_sync_text(p_row,'Plate'),''), '\s', '', 'g'))),
      'legacy_status', integration.legacy_sync_text(p_row,'Status'),
      'active', v_active and v_status in ('available','maintenance'),
      'operational_status', case when not v_active or v_status not in ('available','maintenance') then 'OUT_OF_SERVICE'
                                 when v_status = 'maintenance' then 'MAINTENANCE' else 'AVAILABLE' end,
      'notes', integration.legacy_sync_text(p_row,'Notes'),
      'maintenance_start_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'MaintStart'),10)),
      'maintenance_end_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'MaintEnd'),10)),
      'contract_type', integration.legacy_sync_text(p_row,'ContractType'),
      'vehicle_description', integration.legacy_sync_text(p_row,'VehicleDescription'),
      'tachograph_type', integration.legacy_sync_text(p_row,'TachographType'),
      'insurer_legacy_value', integration.legacy_sync_text(p_row,'Insurer'),
      'make', integration.legacy_sync_text(p_row,'Make'),
      'model_range', integration.legacy_sync_text(p_row,'Range'),
      'test_expires_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'CvrtMotExpiryDate'),10)),
      'tacho_calibration_due_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TachoCalibrationDate'),10)),
      'fuel_code', integration.legacy_sync_text(p_row,'Fuel'),
      'odometer_km', integration.legacy_sync_parse_number(integration.legacy_sync_text(p_row,'LastKmRecorded')),
      'contract_start_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'ContractStartDate'),10)),
      'contract_end_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'ContractEndDate'),10)),
      'body_detail', integration.legacy_sync_text(p_row,'BodyDetail'),
      'tail_lift_detail_1', integration.legacy_sync_text(p_row,'TailLiftDetail1'),
      'tail_lift_detail_2', integration.legacy_sync_text(p_row,'TailLiftDetail2'),
      'monthly_rental_ex_vat', integration.legacy_sync_parse_number(integration.legacy_sync_text(p_row,'MonthlyRentalExVat')),
      'contract_term_months', round(integration.legacy_sync_parse_number(integration.legacy_sync_text(p_row,'TermMonths')))::integer,
      'cvrt_last_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'CvrtLast'),10)),
      'service_last_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'ServiceLast'),10)),
      'service_due_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'ServiceNext'),10)),
      'tachograph_last_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TachographLast'),10)),
      'road_tax_expires_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'RoadFundLicenceNext'),10)),
      'tail_lift_weight_test_last_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TlWeightTestLast'),10)),
      'tail_lift_weight_test_due_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TlWeightTestNext'),10)),
      'registration_date', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'RegistrationDate'),10)),
      'tail_lift_loler_due_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TlLolerNext'),10)),
      'tail_lift_loler_last_on', integration.legacy_sync_parse_date(left(integration.legacy_sync_text(p_row,'TlLolerLast'),10)),
      'legacy_registered_at', integration.legacy_sync_parse_instant(integration.legacy_sync_text(p_row,'RegisteredAt')),
      'legacy_updated_at', integration.legacy_sync_parse_instant(integration.legacy_sync_text(p_row,'UpdatedAt')));
  else
    b := b || integration.legacy_sync_issue('INVALID_RECORD', t);
  end if;

  return jsonb_build_object('want', w, 'blockers', b, 'warnings', n);
end;
$$;

-- The same fields as they are in V2 today. Read-only.
create or replace function integration.legacy_sync_master_have(p_type text, p_target uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select case upper(p_type)
    when 'STAFF' then (
      select jsonb_build_object('display_name', s.display_name, 'active', s.active, 'joined_on', s.joined_on,
        'deactivated_on', s.deactivated_on, 'roster_eligible', s.roster_eligible,
        'fire_training', s.fire_training, 'first_aid_training', s.first_aid_training, 'eod_capable', s.eod_capable,
        'shift_code', sh.shift_code, 'role_code', r.role_code, 'area_code', a.area_code, 'station_code', st.station_code,
        'covers', (select coalesce(jsonb_agg(distinct cr.role_code order by cr.role_code), '[]'::jsonb)
                   from public.staff_cover_capabilities c
                   join public.operational_roles cr on cr.operational_role_id=c.operational_role_id
                   where c.staff_id=s.staff_id and c.active and c.effective_until is null and c.deleted_at is null),
        'deleted', s.deleted_at is not null, 'row_version', s.row_version)
      from public.staff_members s
      left join public.shifts sh on sh.shift_id=s.default_shift_id
      left join public.operational_roles r on r.operational_role_id=s.primary_operational_role_id
      left join public.areas a on a.area_id=s.default_area_id
      left join public.stations st on st.station_id=s.default_station_id
      where s.staff_id=p_target)
    when 'CUSTOMER' then (
      select jsonb_build_object('customer_name', c.customer_name, 'eircode', c.eircode, 'active', c.active,
        'distribution_estimated_kg', c.distribution_estimated_kg, 'distribution_stop_count', c.distribution_stop_count,
        'notes', c.notes,
        'product_codes', (select coalesce(jsonb_agg(distinct pt.product_code order by pt.product_code), '[]'::jsonb)
                          from public.customer_product_services ps
                          join public.product_types pt on pt.product_type_id=ps.product_type_id
                          where ps.customer_id=c.customer_id and ps.active and ps.effective_until is null and ps.deleted_at is null),
        'legacy_service_type', c.legacy_metadata->>'legacy_service_type',
        'legacy_customer_type', c.legacy_metadata->>'legacy_customer_type',
        'deleted', c.deleted_at is not null, 'row_version', c.row_version)
      from public.customers c where c.customer_id=p_target)
    when 'TROLLEY' then (
      select jsonb_build_object('trolley_type_code', tt.trolley_type_code,
        'service_status', case t.status when 'OUT_OF_SERVICE' then 'OUT_OF_SERVICE' when 'RETIRED' then 'RETIRED' else 'IN_SERVICE' end,
        'notes', t.notes,
        'status', t.status, 'deleted', t.deleted_at is not null,
        'open_stay', exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and s.received_on is null))
      from public.trolleys t left join public.trolley_types tt on tt.trolley_type_id=t.trolley_type_id
      where t.trolley_id=p_target)
    when 'DRIVER' then (
      select jsonb_build_object('display_name', d.display_name,
        'licence_categories', (select coalesce(jsonb_agg(distinct upper(x) order by upper(x)), '[]'::jsonb) from unnest(d.licence_categories) x),
        'employment_status', d.employment_status, 'joined_on', d.joined_on, 'deactivated_on', d.deactivated_on,
        'roster_hidden', d.roster_hidden, 'deleted', d.deleted_at is not null, 'row_version', d.row_version)
      from public.distribution_drivers d where d.driver_id=p_target)
    when 'VEHICLE' then (
      select (to_jsonb(v) - array['vehicle_id','registration_number','capacity_kg','capacity_m3','capacity_trolleys',
                                  'insurance_expires_on','created_at','created_by','updated_at','updated_by','deleted_at',
                                  'is_temporary','available_until','hire_company','import_source'])
             || jsonb_build_object('deleted', v.deleted_at is not null)
      from public.fleet_vehicles v where v.vehicle_id=p_target)
  end;
$$;

-- Generic column setter for the plain fields (keys are column names).
create or replace function integration.legacy_sync_master_set(
  p_table regclass, p_id_column text, p_id uuid, p_keys text[], p_values jsonb, p_bump_row_version boolean)
returns void
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_sets text;
begin
  select string_agg(format('%I = r.%I', k, k), ', ') into v_sets from unnest(p_keys) k;
  if v_sets is null then return; end if;
  if p_bump_row_version then
    v_sets := v_sets || ', row_version = t.row_version + 1';
  end if;
  execute format('update %s t set %s from jsonb_populate_record(null::%s, $1) r where t.%I = $2',
                 p_table, v_sets, p_table, p_id_column)
  using p_values, p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Planner. Read-only.
--
-- p_record: { "record_type": "STAFF"|"CUSTOMER"|"TROLLEY"|"DRIVER"|"VEHICLE",
--             "source_record_id": "<key>", "row": { <sheet columns> } }
-- Actions: CREATE, ADOPT, ADOPT_BY_NAME, UPDATE, RELINK.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_master(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_spec jsonb := integration.legacy_sync_master_spec(p_record->>'record_type');
  v_built jsonb;
  v_want jsonb;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_state integration.legacy_sync_master_states%rowtype;
  v_target uuid;
  v_via text;
  v_have jsonb;
  v_changed text[];
  v_apply text[];
  v_differs text[];
  v_action text;
  v_n integer;
  v_key text;
begin
  if v_row is null or v_spec is null then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type),'warnings','[]'::jsonb);
  end if;

  v_built := integration.legacy_sync_master_want(v_type, v_row);
  v_want := v_built->'want';
  v_blockers := v_built->'blockers';
  v_warnings := v_built->'warnings';
  v_fp := integration.legacy_sync_fingerprint(v_want);

  if v_id is null or length(v_id) > 160 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  elsif integration.legacy_sync_text(v_row, v_spec->>'id_field') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
  end if;
  if v_type = 'STAFF' and v_id !~ '^[0-9]{1,6}$' then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_USER_ID', v_id);
  end if;
  if v_type = 'DRIVER' and v_id !~ '^[0-9]{1,4}$' then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_DRIVER_ID', v_id);
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system='CENTRALDB' and l.source_table=v_spec->>'table' and l.source_record_id=v_id
    and l.link_role=v_spec->>'role' and l.source_line_key='';

  if v_link.link_id is not null then
    v_target := v_link.target_id; v_via := 'LINK';
  elsif v_id is not null then
    case v_type
      when 'STAFF' then
        if v_id ~ '^[0-9]{1,6}$' then
          select s.staff_id into v_target from public.staff_members s where s.legacy_user_id=v_id::integer;
          v_via := 'LEGACY_USER_ID';
        end if;
        if v_target is null then
          select count(*), min(s.staff_id::text)::uuid into v_n, v_target
          from public.staff_members s
          where s.legacy_user_id is null and s.deleted_at is null
            and integration.legacy_sync_name_key(s.display_name) = integration.legacy_sync_name_key(v_want->>'display_name');
          if v_n > 1 then
            v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NAME_AMBIGUOUS', v_want->>'display_name');
            v_target := null;
          end if;
          v_via := case when v_target is not null then 'NAME' end;
        end if;
      when 'CUSTOMER' then
        select c.customer_id into v_target from public.customers c
        where c.customer_code = upper(v_id) or c.legacy_metadata->>'legacy_customer_id' = v_id
        order by (c.customer_code = upper(v_id)) desc limit 1;
        v_via := 'CUSTOMER_CODE';
      when 'TROLLEY' then
        select t.trolley_id into v_target from public.trolleys t where lower(t.trolley_code) = lower(v_id);
        v_via := 'TROLLEY_CODE';
      when 'DRIVER' then
        select d.driver_id into v_target from public.distribution_drivers d
        where d.legacy_driver_id = v_id or (v_id ~ '^[0-9]{1,4}$' and d.driver_code = 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0'))
        order by (d.legacy_driver_id = v_id) desc nulls last limit 1;
        v_via := 'DRIVER_CODE';
      when 'VEHICLE' then
        select v.vehicle_id into v_target from public.fleet_vehicles v
        where upper(regexp_replace(v.registration_number, '\s', '', 'g')) = upper(regexp_replace(v_id, '\s', '', 'g'));
        v_via := 'REGISTRATION';
    end case;
  end if;

  if v_target is not null then
    v_have := integration.legacy_sync_master_have(v_type, v_target);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings,'target_id',v_target);
  end if;

  if v_target is not null and (v_have->>'deleted')::boolean then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','DELETED_IN_V2','target_id',v_target,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if v_link.link_id is not null then
    select * into v_state from integration.legacy_sync_master_states s
    where s.source_system='CENTRALDB' and s.source_table=v_spec->>'table' and s.source_record_id=v_id
    order by s.state_id desc limit 1;
    if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,
        'fingerprint',v_fp,'target_id',v_target,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
    -- Fields the legacy app changed since the last sync; of those, the ones V2 does not have yet.
    select array_agg(k order by k) into v_changed from jsonb_object_keys(v_want) k
    where k !~ '^_' and (v_want->k) is distinct from coalesce(v_state.synced->k, 'null'::jsonb);
    select array_agg(k order by k) into v_apply from unnest(coalesce(v_changed, '{}'::text[])) k
    where (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb)
      and not (k = 'product_codes' and v_want->k = 'null'::jsonb);
    v_action := case when coalesce(cardinality(v_apply),0) = 0 then 'RELINK' else 'UPDATE' end;
  elsif v_target is not null then
    v_action := case when v_via = 'NAME' then 'ADOPT_BY_NAME' else 'ADOPT' end;
    -- An empty legacy cell is not listed: only real disagreements are.
    select array_agg(k order by k) into v_differs from jsonb_object_keys(v_want) k
    where k !~ '^_' and v_want->k <> 'null'::jsonb
      and (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb);
    if v_differs is not null then
      v_warnings := v_warnings || integration.legacy_sync_issue('V2_DIFFERS',
        (select string_agg(k || ': V2 ' || coalesce(v_have->>k,'-') || ' / legacy ' || coalesce(v_want->>k,'-'), '; ')
         from unnest(v_differs) k));
    end if;
  else
    v_action := 'CREATE';
    select array_agg(k order by k) into v_apply from jsonb_object_keys(v_want) k where k !~ '^_';
  end if;

  -- Writes V2 would refuse on its own screens.
  if v_action in ('CREATE','UPDATE') then
    if v_type = 'TROLLEY' and 'service_status' = any(v_apply) then
      if v_want->>'service_status' in ('OUT_OF_SERVICE','RETIRED') and coalesce((v_have->>'open_stay')::boolean, false) then
        v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_AT_CUSTOMER', v_want->>'service_status');
      elsif v_have->>'service_status' = 'RETIRED' then
        v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_RETIRED_IN_V2');
      end if;
    end if;
    if v_type = 'CUSTOMER' and (v_want->>'active')::boolean and v_want->'product_codes' = 'null'::jsonb
       and (v_action = 'CREATE' or ('active' = any(v_apply) and not coalesce((v_have->>'active')::boolean, false))) then
      v_blockers := v_blockers || integration.legacy_sync_issue('SERVICE_TYPE_REQUIRED');
    end if;
    if v_type = 'DRIVER' and v_action = 'CREATE' and exists (
        select 1 from public.distribution_drivers d where d.driver_code = 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0')) then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_CODE_TAKEN', 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0'));
    end if;
    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'action',v_action,'blockers',v_blockers,'warnings',v_warnings,'target_id',v_target);
    end if;
  end if;

  return jsonb_build_object('outcome','READY','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'target_id',v_target,'matched_by',v_via,
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k,'null'::jsonb), 'legacy', v_want->k)), '{}'::jsonb)
                from unnest(coalesce(v_apply, '{}'::text[])) k),
    'want', v_want, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run: 1-60 records. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_master_dry_run(p_records jsonb)
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
    raise exception using errcode='22023', message='Send between 1 and 60 legacy register records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_master(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id'
          and o->>'record_type' is not distinct from v_plan->>'record_type') > 1
       and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH'));
    end if;
    v_out := v_out || jsonb_build_array(v_plan - 'want');
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
-- 5. Writer: the fields p_keys of one register record, as the V2 screens
--    write them. p_target null creates the record. Returns the V2 id.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_master_apply(
  p_type text, p_source_id text, p_target uuid, p_keys text[], p_want jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_MASTER';
  c_reason constant text := 'Changed in the legacy CentralDB (legacy sync).';
  v_type text := upper(p_type);
  v_id uuid := p_target;
  v_keys text[] := coalesce(p_keys, '{}'::text[]);
  v_have jsonb;
  v_today date := public.current_business_date();
  v_status text;
  v_role_id uuid;
begin
  if v_type = 'STAFF' then
    if v_id is null then
      insert into public.staff_members(display_name, legacy_user_id, production_staff, roster_eligible, notes)
      values (p_want->>'display_name', p_source_id::integer, true, false,
              'Created from the legacy CentralDB User sheet (legacy sync).')
      returning staff_id into v_id;
    end if;
    perform integration.legacy_sync_master_set('public.staff_members', 'staff_id', v_id,
      array(select k from unnest(v_keys) k where k in ('display_name','joined_on','fire_training','first_aid_training','eod_capable')),
      p_want, true);
    if 'shift_code' = any(v_keys) then
      update public.staff_members set default_shift_id=(select shift_id from public.shifts where shift_code=p_want->>'shift_code')
      where staff_id=v_id;
    end if;
    if 'role_code' = any(v_keys) then
      update public.staff_members set primary_operational_role_id=(select operational_role_id from public.operational_roles where role_code=p_want->>'role_code')
      where staff_id=v_id;
    end if;
    if 'area_code' = any(v_keys) then
      update public.staff_members set default_area_id=(select area_id from public.areas where area_code=p_want->>'area_code')
      where staff_id=v_id;
    end if;
    if 'station_code' = any(v_keys) then
      update public.staff_members set default_station_id=(select station_id from public.stations where station_code=p_want->>'station_code')
      where staff_id=v_id;
    end if;
    if 'active' = any(v_keys) then
      if (p_want->>'active')::boolean then
        update public.staff_members
        set active=true, deactivated_on=null, deactivation_reason=null, roster_eligible=(p_want->>'roster_eligible')::boolean,
            row_version=row_version+1
        where staff_id=v_id and not active;
      else
        update public.staff_members
        set active=false, roster_eligible=false, deactivated_on=coalesce((p_want->>'deactivated_on')::date, v_today),
            deactivation_reason='Deactivated in the legacy CentralDB (legacy sync).', row_version=row_version+1
        where staff_id=v_id and active;
      end if;
    end if;
    if 'deactivated_on' = any(v_keys) and not (p_want->>'active')::boolean and p_want->>'deactivated_on' is not null then
      update public.staff_members set deactivated_on=(p_want->>'deactivated_on')::date where staff_id=v_id and not active;
    end if;
    if 'roster_eligible' = any(v_keys) then
      update public.staff_members set roster_eligible=(p_want->>'roster_eligible')::boolean and active
      where staff_id=v_id;
    end if;
    if 'covers' = any(v_keys) then
      update public.staff_cover_capabilities c
      set active=false, effective_until=greatest(v_today, c.effective_from), updated_at=now()
      from public.operational_roles r
      where r.operational_role_id=c.operational_role_id and c.staff_id=v_id
        and c.active and c.effective_until is null and c.deleted_at is null
        and not (p_want->'covers') ? r.role_code;
      insert into public.staff_cover_capabilities(staff_id, operational_role_id, effective_from)
      select v_id, r.operational_role_id, v_today
      from jsonb_array_elements_text(p_want->'covers') code
      join public.operational_roles r on r.role_code=code
      where not exists (select 1 from public.staff_cover_capabilities c
                        where c.staff_id=v_id and c.operational_role_id=r.operational_role_id
                          and c.active and c.effective_until is null and c.deleted_at is null);
    end if;

  elsif v_type = 'CUSTOMER' then
    if v_id is null then
      insert into public.customers(customer_code, customer_name, active, notes, legacy_metadata)
      values (upper(p_source_id), p_want->>'customer_name', true, null,
              jsonb_build_object('source','LEGACY_SYNC','legacy_customer_id',p_source_id))
      returning customer_id into v_id;
    end if;
    perform integration.legacy_sync_master_set('public.customers', 'customer_id', v_id,
      array(select k from unnest(v_keys) k
            where k in ('customer_name','eircode','distribution_estimated_kg','distribution_stop_count','notes')),
      p_want, false);
    if v_keys && array['legacy_service_type','legacy_customer_type'] then
      update public.customers
      set legacy_metadata = legacy_metadata || jsonb_build_object(
            'legacy_service_type', p_want->'legacy_service_type', 'legacy_customer_type', p_want->'legacy_customer_type')
      where customer_id=v_id;
    end if;
    select active::text into v_status from public.customers where customer_id=v_id;
    if 'active' = any(v_keys) and not (p_want->>'active')::boolean and v_status = 'true' then
      -- As deactivate_customer.
      update public.customers
      set active=false, deactivated_at=now(), deactivated_by=null,
          deactivation_reason='Deactivated in the legacy CentralDB (legacy sync).', updated_by=null
      where customer_id=v_id;
      update public.customer_product_services
      set active=false, effective_until=v_today, updated_by=null
      where customer_id=v_id and active and deleted_at is null;
      update public.customer_schedule_versions
      set status='CANCELLED', cancelled_at=now(), cancelled_by=null,
          change_reason=concat_ws(' | ', change_reason, 'Customer deactivated in the legacy CentralDB.'), updated_by=null
      where customer_id=v_id and status='DRAFT';
      update public.customer_schedule_versions
      set status='SUPERSEDED',
          effective_until=case when effective_from < v_today
            then least(coalesce(effective_until, v_today - 1), v_today - 1) else effective_until end,
          superseded_at=now(), superseded_by=null,
          change_reason=concat_ws(' | ', change_reason, 'Customer deactivated in the legacy CentralDB.'), updated_by=null
      where customer_id=v_id and status='PUBLISHED';
    elsif (p_want->>'active')::boolean
          and (('active' = any(v_keys) and v_status = 'false') or 'product_codes' = any(v_keys))
          and p_want->'product_codes' <> 'null'::jsonb then
      -- As reactivate_customer / update_customer: the product services follow the legacy service type.
      update public.customers set active=true, deactivated_at=null, deactivated_by=null, deactivation_reason=null
      where customer_id=v_id and not active;
      update public.customer_product_services ps
      set active=false, effective_until=v_today, updated_by=null
      from public.product_types pt
      where pt.product_type_id=ps.product_type_id and ps.customer_id=v_id and ps.active and ps.deleted_at is null
        and not (p_want->'product_codes') ? pt.product_code;
      insert into public.customer_product_services(customer_id, product_type_id, effective_from, active)
      select v_id, pt.product_type_id, v_today, true
      from jsonb_array_elements_text(p_want->'product_codes') code
      join public.product_types pt on pt.product_code=code and pt.active and pt.deleted_at is null
      where not exists (select 1 from public.customer_product_services ps
                        where ps.customer_id=v_id and ps.product_type_id=pt.product_type_id
                          and ps.active and ps.effective_until is null and ps.deleted_at is null);
    end if;

  elsif v_type = 'TROLLEY' then
    if v_id is null then
      insert into public.trolleys(trolley_code, trolley_type_id, status, active, registered_on, notes, metadata)
      values (upper(p_source_id),
              (select trolley_type_id from public.trolley_types where trolley_type_code=p_want->>'trolley_type_code'),
              'AVAILABLE', true, coalesce((p_want->>'_registered_on')::date, v_today), p_want->>'notes',
              jsonb_build_object('source','LEGACY_SYNC','legacy_trolley_id',p_source_id))
      returning trolley_id into v_id;
      insert into public.trolley_events(trolley_id, event_type, business_date, source_application, reason, metadata)
      values (v_id, 'TROLLEY_REGISTERED', coalesce((p_want->>'_registered_on')::date, v_today), c_source,
              'Registered in the legacy CentralDB (legacy sync).',
              jsonb_build_object('trolley_type_code', p_want->>'trolley_type_code'));
      v_keys := array(select k from unnest(v_keys) k where k = 'service_status');
    end if;
    if 'trolley_type_code' = any(v_keys) then
      update public.trolleys set trolley_type_id=(select trolley_type_id from public.trolley_types where trolley_type_code=p_want->>'trolley_type_code')
      where trolley_id=v_id;
    end if;
    perform integration.legacy_sync_master_set('public.trolleys', 'trolley_id', v_id,
      array(select k from unnest(v_keys) k where k = 'notes'), p_want, false);
    if 'service_status' = any(v_keys) then
      select status into v_status from public.trolleys where trolley_id=v_id for update;
      if p_want->>'service_status' = 'OUT_OF_SERVICE' and v_status not in ('OUT_OF_SERVICE','RETIRED') then
        update public.trolleys set status_before_service_hold=status, status='OUT_OF_SERVICE' where trolley_id=v_id;
        insert into public.trolley_events(trolley_id, event_type, business_date, source_application, reason)
        values (v_id, 'MARKED_OUT_OF_SERVICE', v_today, c_source, c_reason);
      elsif p_want->>'service_status' = 'IN_SERVICE' and v_status = 'OUT_OF_SERVICE' then
        update public.trolleys
        set status=case when status_before_service_hold in ('LOCATION_UNCONFIRMED','AVAILABLE') then status_before_service_hold else 'AVAILABLE' end,
            status_before_service_hold=null
        where trolley_id=v_id;
        insert into public.trolley_events(trolley_id, event_type, business_date, source_application, reason)
        values (v_id, 'RETURNED_TO_SERVICE', v_today, c_source, c_reason);
      elsif p_want->>'service_status' = 'RETIRED' and v_status <> 'RETIRED' then
        update public.trolleys set status='RETIRED', active=false, retired_on=greatest(v_today, registered_on), status_before_service_hold=null
        where trolley_id=v_id;
        insert into public.trolley_events(trolley_id, event_type, business_date, source_application, reason)
        values (v_id, 'TROLLEY_RETIRED', v_today, c_source, c_reason);
      end if;
    end if;

  elsif v_type = 'DRIVER' then
    if v_id is null then
      insert into public.distribution_drivers(driver_code, display_name, legacy_driver_id, import_source, notes)
      values ('DRV-' || lpad(p_source_id, greatest(3, length(p_source_id)), '0'), p_want->>'display_name', p_source_id, 'LEGACY_SYNC',
              'Created from the legacy CentralDB Driver sheet (legacy sync).')
      returning driver_id into v_id;
    end if;
    perform integration.legacy_sync_master_set('public.distribution_drivers', 'driver_id', v_id,
      array(select k from unnest(v_keys) k where k in ('display_name','licence_categories','joined_on','deactivated_on','roster_hidden')),
      p_want, true);
    if 'employment_status' = any(v_keys) then
      update public.distribution_drivers
      set employment_status=p_want->>'employment_status',
          availability_status=case when p_want->>'employment_status'='ACTIVE' then 'AVAILABLE' else 'UNAVAILABLE' end,
          deactivated_on=case when p_want->>'employment_status'='ACTIVE' then null
                              else coalesce((p_want->>'deactivated_on')::date, deactivated_on, v_today) end,
          deactivation_reason=case when p_want->>'employment_status'='ACTIVE' then null
                                   else 'Deactivated in the legacy CentralDB (legacy sync).' end
      where driver_id=v_id;
    end if;

  elsif v_type = 'VEHICLE' then
    if v_id is null then
      insert into public.fleet_vehicles(registration_number, vehicle_type, import_source)
      values (upper(regexp_replace(p_source_id, '\s', '', 'g')), coalesce(p_want->>'vehicle_type','OTHER'), 'LEGACY_SYNC')
      returning vehicle_id into v_id;
    end if;
    perform integration.legacy_sync_master_set('public.fleet_vehicles', 'vehicle_id', v_id, v_keys, p_want, true);
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Importer: one record, or {"records": [...]} up to 60, each in its own
--    subtransaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_master_one(
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
  c_source constant text := 'LEGACY_SYNC_MASTER';
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_spec jsonb := integration.legacy_sync_master_spec(p_record->>'record_type');
  v_plan jsonb;
  v_action text;
  v_target uuid;
  v_old jsonb;
  v_new jsonb;
  v_done integer;
  v_keys text[];
begin
  if v_spec is null or v_id is null then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_MASTER:' || v_type || ':' || lower(v_id), 0));
  v_plan := integration.legacy_sync_plan_master(p_record);
  perform integration.legacy_sync_keep_version('CENTRALDB', v_spec->>'table', v_id, v_plan->>'fingerprint', p_record->'row', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review('CENTRALDB', v_spec->>'table', v_plan, p_record, p_sync_run_id);
    return v_plan - 'want';
  end if;

  v_action := v_plan->>'action';
  v_target := nullif(v_plan->>'target_id','')::uuid;

  if v_action in ('CREATE','UPDATE','ADOPT_BY_NAME') then
    select count(*) into v_done from public.audit_log a
    where a.correlation_id=p_sync_run_id
      and a.action in ('IMPORT_LEGACY_MASTER','UPDATE_LEGACY_MASTER','ADOPT_LEGACY_MASTER');
    if v_done >= p_limit then
      return jsonb_build_object('outcome','RUN_LIMIT_REACHED','record_type',v_type,'source_record_id',v_id,
        'max_entries_per_run',p_limit);
    end if;
  end if;

  if v_target is not null then
    v_old := integration.legacy_sync_master_have(v_type, v_target);
  end if;

  if v_action = 'ADOPT_BY_NAME' then
    update public.staff_members set legacy_user_id=v_id::integer, row_version=row_version+1
    where staff_id=v_target and legacy_user_id is null;
    if not found then
      raise exception using errcode='40001', message='The V2 staff record changed during import. Retry.';
    end if;
  elsif v_action in ('CREATE','UPDATE') then
    select array_agg(k) into v_keys from jsonb_object_keys(v_plan->'changes') k;
    v_target := integration.legacy_sync_master_apply(v_type, v_id, v_target, v_keys, v_plan->'want');
  end if;

  if v_action in ('CREATE','ADOPT','ADOPT_BY_NAME') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values ('CENTRALDB', v_spec->>'table', v_id, v_spec->>'role', v_spec->>'target', v_target,
      v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('action', v_action, 'matched_by', v_plan->>'matched_by', 'warnings', v_plan->'warnings'));
  end if;

  insert into integration.legacy_sync_master_states(source_system, source_table, source_record_id, target_table,
    target_id, action, synced, source_fingerprint, sync_run_id)
  values ('CENTRALDB', v_spec->>'table', v_id, v_spec->>'target', v_target, v_action, v_plan->'want',
    v_plan->>'fingerprint', p_sync_run_id);

  if v_action in ('CREATE','UPDATE','ADOPT_BY_NAME') then
    v_new := integration.legacy_sync_master_have(v_type, v_target);
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values (case v_action when 'CREATE' then 'IMPORT_LEGACY_MASTER' when 'UPDATE' then 'UPDATE_LEGACY_MASTER'
                          else 'ADOPT_LEGACY_MASTER' end,
      v_spec->>'entity', v_target::text, v_old, v_new,
      'Legacy sync: CentralDB ' || (v_spec->>'table') || ' ' || v_id ||
        case when v_action = 'UPDATE' then ' changed ' || array_to_string(v_keys, ', ') else '' end || '.',
      c_source, p_sync_run_id);
  end if;

  return (v_plan - 'want') || jsonb_build_object('outcome',
    case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' when 'RELINK' then 'RELINKED' else 'ADOPTED' end,
    'imported', true, 'target_id', v_target);
end;
$$;

create or replace function integration.legacy_sync_import_master(
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
  where setting_key='MASTER_DATA_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy register import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  if jsonb_typeof(p_record->'records') = 'array' then
    v_records := p_record->'records';
    if jsonb_array_length(v_records) = 0 or jsonb_array_length(v_records) > 60 then
      raise exception using errcode='22023', message='Send between 1 and 60 legacy register records.';
    end if;
  else
    v_records := jsonb_build_array(p_record);
  end if;

  for v_record in select value from jsonb_array_elements(v_records) loop
    begin
      v_result := integration.legacy_sync_import_master_one(p_sync_run_id, v_record, v_setting.max_entries_per_run);
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
-- 7. Dispatchers: add the kind "master".
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
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_yes(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_name_key(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_spec(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_want(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_have(text, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_set(regclass, text, uuid, text[], jsonb, boolean) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_master(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_master_apply(text, text, uuid, text[], jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_master_one(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_master(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_master_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_master(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_master(jsonb) is
  'Read-only plan of one legacy CentralDB register row (User, CustomerMaster, Trolley, Driver, Vehicles).';
comment on function integration.legacy_sync_master_dry_run(jsonb) is
  'Read-only dry run of 1-60 legacy register rows.';
comment on function integration.legacy_sync_import_master(uuid, jsonb) is
  'Imports one legacy register row, or a batch of up to 60, behind MASTER_DATA_IMPORT. service_role only.';

commit;
