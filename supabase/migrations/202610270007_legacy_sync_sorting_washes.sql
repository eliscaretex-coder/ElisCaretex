-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270007_legacy_sync_sorting_washes
--
-- Owner decision 2026-10-27 (Paulo Bressan): everything the legacy apps
-- still record goes to V2 through the nightly sync, as if the team had
-- typed it in V2. This migration adds the first part: Sorting washes.
-- Depends on 202610270001 to 202610270006.
--
-- Source (sent by the Apps Script, one wash per call):
--   * the Sorting workbook sheet "Sorting Area": one row per washer load
--     (WashID, START TIME, REGISTER TIME, MACHINE, WHO, Type, KG);
--   * CentralDB WashItems (+ WashItemsHistory): one row per customer in the
--     load (WashItemID, WashID, CustomerID, ScheduledDate, Type, KGShare);
--   * the Sorting workbook sheet "Staff": the shifts the operator worked
--     that day. The legacy load has no shift of its own.
--
-- What one import writes, the same rows as save_sorting_wash_run_v2:
--   * a sorting_wash_runs row whose wash_code is the legacy WashID, with
--     source_application LEGACY_SYNC_SORTING;
--   * one sorting_wash_run_customers row per customer, with the published
--     schedule snapshot of the legacy scheduled date. The existing triggers
--     then split the load weight, link the customer to its Production Flow
--     (the same flow the Finish importer uses) and append WASH_RECORDED;
--   * an audit_log row and a SORTING_WASH_TO_RUN provenance link.
-- A changed legacy load is applied as a V2 correction: the current run is
-- cancelled and a CORRECTION run replaces it (wash_code WashID-R2, -R3...).
-- Loads already in V2 from the 2026-10-24 workbook import (wash_code =
-- WashID) are adopted, not imported twice.
--
-- Rules:
--   * shift: the operator's shift on the legacy Staff sheet; when it is
--     missing or ambiguous, the clock (before 14:00 Morning, else Evening;
--     up to 03:00 is the previous Evening);
--   * type OTHERS is CLOTHES (owner decision 2026-10-27, value map);
--   * entry mode LATE_ENTRY when the load was registered more than 60
--     minutes after its start, else LIVE;
--   * Sunday 2026-10-25 was an owner test day: skipped. Loads before
--     2026-10-24 are skipped unless already linked;
--   * the V2 screen limits (operator on the Sorting roster, reception scan,
--     20 customers, active customer) are checks for people typing live.
--     Here the legacy record is the truth: an unknown washer, operator or
--     customer, a weight over capacity, an operator marked absent in V2 or
--     an inactive customer goes to the review queue instead.
--
-- New switch SORTING_WASH_IMPORT (seeded OFF, limit 300). The Apps Script
-- control ON/OFF now switches every import switch together.
-- New generic dispatchers (dry run / import by kind) let the next sync parts
-- reach the database without another Edge Function deploy.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch and provenance role
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('SORTING_WASH_IMPORT', false, 300, 'migration 202610270007',
        'Seeded disabled. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE','SORTING_WASH_TO_RUN')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='HOUSEHOLD_TO_REWASH_ENTRY' and target_table='public.finish_rewash_entries') or
    (link_role='REWASH_LINE_TO_LINE' and target_table='public.finish_rewash_lines') or
    (link_role='SORTING_WASH_TO_RUN' and target_table='public.sorting_wash_runs')
  );

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- Latest run of a correction chain (a correction points back with replaces_wash_run_id).
create or replace function integration.legacy_sync_wash_current_run(p_wash_run_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_id uuid := p_wash_run_id;
  v_next uuid;
  i integer := 0;
begin
  loop
    select wr.wash_run_id into v_next
    from public.sorting_wash_runs wr
    where wr.replaces_wash_run_id = v_id
    order by wr.created_at desc
    limit 1;
    exit when v_next is null or i > 50;
    v_id := v_next;
    v_next := null;
    i := i + 1;
  end loop;
  return v_id;
end;
$$;

-- Comparable facts of a V2 run. p_physical drops the scheduled dates and
-- reads OTHERS as CLOTHES (used to adopt rows of the 2026-10-24 workbook import).
create or replace function integration.legacy_sync_wash_facts(p_wash_run_id uuid, p_physical boolean)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select jsonb_build_object(
    'business_date', wr.business_date,
    'shift_code', wr.shift_code_snapshot,
    'washer_code', wr.washer_code_snapshot,
    'operator_staff_id', wr.operator_staff_id,
    'wash_type', case when p_physical and wr.wash_type='OTHERS' then 'CLOTHES' else wr.wash_type end,
    'started_at', to_char(wr.started_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'weight_kg', trim_scale(wr.total_weight_kg),
    'customers', coalesce((
      select jsonb_agg(case when p_physical then jsonb_build_object('c', c.customer_id)
                            else jsonb_build_object('c', c.customer_id, 'd', c.scheduled_for_date) end
                       order by c.customer_id)
      from public.sorting_wash_run_customers c where c.wash_run_id = wr.wash_run_id), '[]'::jsonb))
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id;
$$;

-- ---------------------------------------------------------------------
-- 3. Planner: one legacy wash. Read-only.
--
-- p_record:
-- {
--   "source_record_id": "<WashID>",
--   "wash":  { WashID, StartTime "HH:mm:ss", RegisterTime "yyyy-MM-ddTHH:mm:ss" (Dublin),
--              Machine, Who, WhoUserID (CentralDB User.UserID of Who, when unique), Type, Kg, Customers },
--   "items": [ { WashItemID, WashID, CustomerID, ScheduledDate, Type, KGShare, LoadNo, WashStatus } ],
--   "staff_shifts": [ "Morning", ... ]   shifts of Who on the legacy Staff sheet that day
-- }
-- Outcomes: READY (CREATE, UPDATE, ADOPT, ADOPT_AND_UPDATE), ALREADY_IMPORTED,
-- SKIPPED (test day, before the sync window) and BLOCKED.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_wash(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'SORTING_AREA';
  c_table constant text := 'Sorting Area';
  v_wash jsonb := coalesce(p_record->'wash', 'null'::jsonb);
  v_items jsonb := coalesce(p_record->'items', 'null'::jsonb);
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_target public.sorting_wash_runs%rowtype;
  v_target_via text;
  v_chain integer := 0;
  v_registered timestamptz;
  v_registered_local timestamp;
  v_start_text text;
  v_start time;
  v_started_local timestamp;
  v_started timestamptz;
  v_shifts text[];
  v_shift_code text;
  v_shift_source text;
  v_shift public.shifts%rowtype;
  v_business date;
  v_washer public.sorting_washers%rowtype;
  v_type_raw text;
  v_type text;
  v_weight numeric;
  v_staff jsonb;
  v_operator public.staff_members%rowtype;
  v_entry_mode text;
  v_item jsonb;
  v_cust jsonb;
  v_customer public.customers%rowtype;
  v_scheduled date;
  v_item_type text;
  v_share numeric;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_snapshot record;
  v_sched jsonb;
  v_relation text;
  v_flow_link uuid;
  v_flow_id uuid;
  v_facts jsonb;
  v_target_facts jsonb;
  v_physical jsonb;
  v_target_physical jsonb;
  v_action text;
  v_outcome text;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or jsonb_typeof(v_wash) <> 'object' then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','The record must contain a wash object.'));
  end if;
  if jsonb_typeof(v_items) <> 'array' then
    v_items := '[]'::jsonb;
  end if;

  if v_id is null or length(v_id) > 120 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  elsif integration.legacy_sync_text(v_wash,'WashID') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH','source_record_id differs from wash.WashID.');
  end if;

  v_fp := integration.legacy_sync_fingerprint(jsonb_build_object('wash', v_wash, 'items', v_items,
            'staff_shifts', coalesce(p_record->'staff_shifts','[]'::jsonb)));

  -- V2 target: our own link, else a run of the 2026-10-24 workbook import with the same code.
  select * into v_link
  from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role='SORTING_WASH_TO_RUN';
  if found then
    v_target_via := 'LINK';
    select * into v_target from public.sorting_wash_runs wr
    where wr.wash_run_id = integration.legacy_sync_wash_current_run(v_link.target_id);
    select count(*) into v_chain from public.sorting_wash_runs wr
    where wr.wash_code = v_id or wr.wash_code like v_id || '-R%';
  elsif v_id is not null then
    select * into v_target from public.sorting_wash_runs wr where wr.wash_code = v_id;
    if found then
      v_target_via := 'WASH_CODE';
      if v_target.source_application <> 'LOCAL_SORTING_WORKBOOK_20261024' then
        v_blockers := v_blockers || integration.legacy_sync_issue('WASH_CODE_IN_USE',
          'A V2 wash with this code was not created by an earlier import.');
      end if;
      select * into v_target from public.sorting_wash_runs wr
      where wr.wash_run_id = integration.legacy_sync_wash_current_run(v_target.wash_run_id);
      select count(*) into v_chain from public.sorting_wash_runs wr
      where wr.wash_code = v_id or wr.wash_code like v_id || '-R%';
    end if;
  end if;
  if v_target.wash_run_id is not null and v_target.status <> 'RECORDED' then
    v_blockers := v_blockers || integration.legacy_sync_issue('TARGET_NOT_ACTIVE',
      'The V2 wash of this legacy load was cancelled in V2.');
  end if;

  -- Times. RegisterTime is Dublin local; the start is the latest StartTime at or before it.
  v_registered := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_wash,'RegisterTime'));
  v_start_text := integration.legacy_sync_text(v_wash,'StartTime');
  if v_start_text ~ '^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$' then
    begin
      v_start := v_start_text::time;
    exception when others then
      v_start := null;
    end;
  end if;
  if v_registered is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_REGISTER_TIME', integration.legacy_sync_text(v_wash,'RegisterTime'));
  elsif v_registered > now() + interval '5 minutes' then
    v_blockers := v_blockers || integration.legacy_sync_issue('REGISTER_TIME_IN_FUTURE', v_registered::text);
  end if;
  if v_start is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_START_TIME', v_start_text);
  end if;
  if v_registered is not null and v_start is not null then
    v_registered_local := v_registered at time zone 'Europe/Dublin';
    v_started_local := v_registered_local::date + v_start;
    if v_started_local > v_registered_local + interval '10 minutes' then
      v_started_local := v_started_local - interval '1 day';
    end if;
    v_started := v_started_local at time zone 'Europe/Dublin';
    v_entry_mode := case when v_registered - v_started > interval '60 minutes' then 'LATE_ENTRY' else 'LIVE' end;
  end if;

  -- Shift: the legacy Staff sheet first, else the clock.
  if v_started_local is not null then
    select array_agg(distinct integration.legacy_sync_map_value('FINISH_AREA','SHIFT', s.value))
    into v_shifts
    from jsonb_array_elements_text(case when jsonb_typeof(p_record->'staff_shifts')='array'
                                        then p_record->'staff_shifts' else '[]'::jsonb end) s(value)
    where integration.legacy_sync_map_value('FINISH_AREA','SHIFT', s.value) is not null;
    if v_started_local::time <= time '03:00' then
      v_shift_code := 'EVENING'; v_shift_source := 'CLOCK_OVERNIGHT';
    elsif coalesce(array_length(v_shifts,1),0) = 1 then
      v_shift_code := v_shifts[1]; v_shift_source := 'STAFF_SHEET';
    else
      v_shift_code := case when v_started_local::time < time '14:00' then 'MORNING' else 'EVENING' end;
      v_shift_source := case when coalesce(array_length(v_shifts,1),0) > 1 then 'CLOCK_TWO_SHIFTS' else 'CLOCK_NO_STAFF_ROW' end;
    end if;
    v_business := v_started_local::date - case when v_shift_code='EVENING' and v_started_local::time <= time '03:00' then 1 else 0 end;
    select * into v_shift from public.shifts s where s.shift_code=v_shift_code and s.deleted_at is null;
    if not found then
      v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_NOT_FOUND', v_shift_code);
    end if;
  end if;

  -- Owner decision 2026-10-27: every legacy row of Sunday 2026-10-25 was a test.
  if v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_business < integration.legacy_sync_finish_window_start() and v_target_via is distinct from 'LINK' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- Washer: the legacy MACHINE text is the V2 washer name.
  select * into v_washer from public.sorting_washers w
  where w.deleted_at is null
    and upper(regexp_replace(btrim(w.washer_name),'\s+',' ','g'))
        = upper(regexp_replace(btrim(coalesce(integration.legacy_sync_text(v_wash,'Machine'),'')),'\s+',' ','g'));
  if not found then
    v_blockers := v_blockers || integration.legacy_sync_issue('WASHER_UNMAPPED', integration.legacy_sync_text(v_wash,'Machine'));
  end if;

  -- Type: CLOTHES, MOP, OTHERS (= CLOTHES).
  v_type_raw := integration.legacy_sync_text(v_wash,'Type');
  v_type := integration.legacy_sync_map_value('CENTRALDB','WASH_ITEM_TYPE', v_type_raw);
  if v_type is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('WASH_TYPE_UNMAPPED', v_type_raw);
  end if;

  -- Weight.
  v_weight := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_wash,'Kg'));
  if v_weight is null or v_weight <= 0 then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_WEIGHT', integration.legacy_sync_text(v_wash,'Kg'));
  elsif v_weight <> round(v_weight, 2) then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_WEIGHT', 'More than 2 decimals: '||v_weight::text);
  elsif v_washer.washer_id is not null and v_weight > v_washer.capacity_kg then
    v_blockers := v_blockers || integration.legacy_sync_issue('WEIGHT_OVER_CAPACITY',
      format('%s KG on %s (%s KG)', v_weight, v_washer.washer_code, v_washer.capacity_kg));
  end if;

  -- Operator: the legacy user ID (CentralDB User, matched by name by the sender), else
  -- exactly one staff member with that display name.
  v_staff := integration.legacy_sync_resolve_staff(integration.legacy_sync_text(v_wash,'WhoUserID'),
                                                   integration.legacy_sync_text(v_wash,'Who'));
  if v_staff->>'staff_id' is null and integration.legacy_sync_text(v_wash,'WhoUserID') is not null then
    v_staff := integration.legacy_sync_resolve_staff(null, integration.legacy_sync_text(v_wash,'Who'));
  end if;
  if v_staff->>'staff_id' is null then
    v_blockers := v_blockers || integration.legacy_sync_issue(
      case when integration.legacy_sync_text(v_wash,'Who') is null then 'OPERATOR_MISSING'
           when v_staff->'warnings' @> '[{"code":"PROCESSED_BY_NAME_AMBIGUOUS"}]' then 'OPERATOR_AMBIGUOUS'
           else 'OPERATOR_UNMATCHED' end,
      concat_ws(' / legacy UserID ', integration.legacy_sync_text(v_wash,'Who'), integration.legacy_sync_text(v_wash,'WhoUserID')));
  else
    select * into v_operator from public.staff_members sm where sm.staff_id=(v_staff->>'staff_id')::uuid;
    if v_shift.shift_id is not null and exists (
         select 1 from public.sorting_daily_staff_attendance a
         where a.business_date=v_business and a.shift_id=v_shift.shift_id
           and a.staff_id=v_operator.staff_id and a.attendance_status='ABSENT') then
      v_blockers := v_blockers || integration.legacy_sync_issue('OPERATOR_MARKED_ABSENT',
        format('%s is ABSENT in V2 Sorting attendance on %s %s.', v_operator.display_name, v_business, v_shift_code));
    end if;
  end if;

  -- Customers: one CentralDB WashItem per customer.
  if jsonb_array_length(v_items) = 0 then
    v_blockers := v_blockers || integration.legacy_sync_issue('NO_WASH_ITEMS',
      'CentralDB WashItems has no row for this WashID.');
  end if;
  for v_item in
    select value from jsonb_array_elements(v_items)
    order by integration.legacy_sync_parse_number(value->>'LoadNo') nulls last, value->>'WashItemID'
  loop
    if integration.legacy_sync_text(v_item,'WashID') is distinct from v_id then
      v_blockers := v_blockers || integration.legacy_sync_issue('WASH_ITEM_WASH_ID_MISMATCH', integration.legacy_sync_text(v_item,'WashItemID'));
      continue;
    end if;
    v_cust := integration.legacy_sync_resolve_customer(integration.legacy_sync_text(v_item,'CustomerID'));
    v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
    if v_cust->>'customer_id' is null then
      continue;
    end if;
    select * into v_customer from public.customers c where c.customer_id=(v_cust->>'customer_id')::uuid;
    if not v_customer.active then
      v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_INACTIVE_PENDING_DECISION', v_customer.customer_code);
    end if;
    v_scheduled := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_item,'ScheduledDate'));
    v_item_type := integration.legacy_sync_map_value('CENTRALDB','WASH_ITEM_TYPE', integration.legacy_sync_text(v_item,'Type'));
    if v_item_type is distinct from v_type then
      v_warnings := v_warnings || integration.legacy_sync_issue('WASH_ITEM_TYPE_DIFFERS',
        format('%s: %s', integration.legacy_sync_text(v_item,'WashItemID'), integration.legacy_sync_text(v_item,'Type')));
    end if;
    v_share := integration.legacy_sync_parse_number(integration.legacy_sync_text(v_item,'KGShare'));

    -- The same customer twice: one V2 row when the scheduled date agrees.
    select value into v_line from jsonb_array_elements(v_lines) where value->>'customer_id' = v_customer.customer_id::text;
    if v_line is not null then
      if v_line->>'scheduled_for_date_raw' is distinct from v_scheduled::text then
        v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_TWICE_IN_LOAD',
          format('%s with two scheduled dates.', v_customer.customer_code));
      else
        select coalesce(jsonb_agg(case when value->>'customer_id' = v_customer.customer_id::text
                 then value || jsonb_build_object(
                   'wash_item_ids', (value->'wash_item_ids') || to_jsonb(integration.legacy_sync_text(v_item,'WashItemID')),
                   'legacy_kg_share', coalesce((value->>'legacy_kg_share')::numeric,0) + coalesce(v_share,0))
                 else value end), '[]'::jsonb)
        into v_lines from jsonb_array_elements(v_lines);
      end if;
      v_line := null;
      continue;
    end if;

    v_relation := 'UNSCHEDULED';
    v_sched := '{}'::jsonb;
    if v_type in ('CLOTHES','MOP') and v_scheduled is not null then
      begin
        select * into v_snapshot from public.sorting_schedule_product_snapshot(v_customer.customer_id, v_type, v_scheduled);
        v_sched := to_jsonb(v_snapshot);
        v_relation := case
          when v_business is null or v_scheduled = v_business then 'TODAY'
          when v_scheduled > v_business then 'EARLY'
          else 'LATE' end;
      exception when others then
        v_sched := '{}'::jsonb;
        v_warnings := v_warnings || integration.legacy_sync_issue('SCHEDULE_NOT_PUBLISHED',
          format('No published %s schedule for %s on %s: recorded as UNSCHEDULED.', v_type, v_customer.customer_code, v_scheduled));
      end;
    elsif v_type in ('CLOTHES','MOP') then
      v_warnings := v_warnings || integration.legacy_sync_issue('NO_SCHEDULED_DATE', integration.legacy_sync_text(v_item,'WashItemID'));
    end if;

    -- The Finish import may already have linked this WashItem to a flow.
    v_flow_link := null; v_flow_id := null;
    select l.target_id into v_flow_link from integration.legacy_sync_record_links l
    where l.source_system='CENTRALDB' and l.source_table='WashItems'
      and l.source_record_id=integration.legacy_sync_text(v_item,'WashItemID') and l.link_role='WASH_ITEM_TO_FLOW';
    if v_relation <> 'UNSCHEDULED' then
      select f.production_flow_item_id into v_flow_id from public.production_flow_items f
      where f.customer_id=v_customer.customer_id and f.product_code=v_type and f.scheduled_for_date=v_scheduled;
    end if;
    if v_flow_link is not null and v_flow_link is distinct from v_flow_id then
      v_warnings := v_warnings || integration.legacy_sync_issue('FINISH_FLOW_DIFFERS',
        format('%s is linked by the Finish import to another Production Flow.', integration.legacy_sync_text(v_item,'WashItemID')));
    end if;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'customer_resolution', v_cust->>'resolution',
      'wash_item_ids', jsonb_build_array(integration.legacy_sync_text(v_item,'WashItemID')),
      'legacy_customer_id', integration.legacy_sync_text(v_item,'CustomerID'),
      'legacy_kg_share', v_share,
      'scheduled_for_date_raw', v_scheduled,
      'schedule_relation', v_relation,
      'scheduled_for_date', case when v_relation <> 'UNSCHEDULED' then v_scheduled end,
      'schedule_version_id', v_sched->>'schedule_version_id',
      'schedule_day_id', v_sched->>'schedule_day_id',
      'schedule_product_id', v_sched->>'schedule_product_id',
      'production_order', v_sched->>'production_order',
      'route_id', v_sched->>'route_id',
      'route_code', v_sched->>'route_code',
      'route_display_name', v_sched->>'route_display_name',
      'route_color', v_sched->>'route_color',
      'production_flow_item_id', v_flow_id));
  end loop;
  if jsonb_array_length(v_lines) > 20 then
    v_warnings := v_warnings || integration.legacy_sync_issue('MORE_THAN_20_CUSTOMERS', jsonb_array_length(v_lines)::text);
  end if;

  v_facts := jsonb_build_object(
    'business_date', v_business, 'shift_code', v_shift_code, 'washer_code', v_washer.washer_code,
    'operator_staff_id', v_operator.staff_id, 'wash_type', v_type,
    'started_at', to_char(v_started at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'weight_kg', trim_scale(v_weight),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('c', (l->>'customer_id')::uuid, 'd', (l->>'scheduled_for_date')::date)
                                            order by (l->>'customer_id')::uuid) from jsonb_array_elements(v_lines) l), '[]'::jsonb));
  v_physical := (v_facts - 'customers') || jsonb_build_object('customers',
    coalesce((select jsonb_agg(jsonb_build_object('c', (l->>'customer_id')::uuid) order by (l->>'customer_id')::uuid)
              from jsonb_array_elements(v_lines) l), '[]'::jsonb));
  if v_target.wash_run_id is not null then
    v_target_facts := integration.legacy_sync_wash_facts(v_target.wash_run_id, false);
    v_target_physical := integration.legacy_sync_wash_facts(v_target.wash_run_id, true);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    v_outcome := 'BLOCKED';
  elsif v_target.wash_run_id is null then
    v_outcome := 'READY'; v_action := 'CREATE';
  elsif v_target_via = 'LINK' and v_target.source_application = 'LEGACY_SYNC_SORTING' and v_facts = v_target_facts then
    v_outcome := 'ALREADY_IMPORTED';
  elsif v_target_via = 'LINK' and v_target.source_application <> 'LEGACY_SYNC_SORTING' and v_physical = v_target_physical then
    -- An adopted run of the 2026-10-24 import has no schedule snapshot: compare the load itself.
    v_outcome := 'ALREADY_IMPORTED';
  elsif v_target_via = 'LINK' then
    v_outcome := 'READY'; v_action := 'UPDATE';
  elsif v_physical = v_target_physical then
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
    'target', case when v_target.wash_run_id is not null then jsonb_build_object(
      'via', v_target_via,
      'wash_run_id', v_target.wash_run_id,
      'wash_code', v_target.wash_code,
      'row_version', v_target.row_version,
      'source_application', v_target.source_application,
      'chain_length', v_chain,
      'facts', v_target_facts) end,
    'resolved', jsonb_build_object(
      'business_date', v_business,
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift_code,
      'shift_source', v_shift_source,
      'washer_id', v_washer.washer_id,
      'washer_code', v_washer.washer_code,
      'washer_name', v_washer.washer_name,
      'washer_capacity_kg', v_washer.capacity_kg,
      'operator_staff_id', v_operator.staff_id,
      'operator_name', v_operator.display_name,
      'operator_resolution', v_staff->>'resolution',
      'wash_type', v_type,
      'legacy_type', v_type_raw,
      'started_at', v_started,
      'registered_at', v_registered,
      'entry_mode', v_entry_mode,
      'weight_kg', v_weight,
      'legacy_customers_text', integration.legacy_sync_text(v_wash,'Customers')),
    'facts', v_facts,
    'customers', v_lines,
    'totals', jsonb_build_object('kg', coalesce(v_weight,0), 'customers', jsonb_array_length(v_lines)));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run: 1-60 legacy washes. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_wash_dry_run(p_records jsonb)
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
    raise exception using errcode='22023', message='Send between 1 and 60 legacy washes.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_wash(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id') > 1
       and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH'));
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
    'ready_kg', (select coalesce(sum((o#>>'{totals,kg}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'ready_customers', (select coalesce(sum((o#>>'{totals,customers}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Importer: one legacy wash, one transaction.
--    CREATE writes the run. UPDATE cancels the current run and writes a
--    CORRECTION run. ADOPT links a run of the 2026-10-24 import;
--    ADOPT_AND_UPDATE links it, then corrects it.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_wash(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'SORTING_AREA';
  c_table constant text := 'Sorting Area';
  c_source constant text := 'LEGACY_SYNC_SORTING';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_plan jsonb;
  v_r jsonb;
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_action text;
  v_done integer;
  v_old public.sorting_wash_runs%rowtype;
  v_new public.sorting_wash_runs%rowtype;
  v_code text;
  v_line jsonb;
  v_pos integer := 0;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='SORTING_WASH_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy Sorting wash import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;
  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_WASH:'||v_id, 0));

  v_plan := integration.legacy_sync_plan_wash(p_record);
  perform integration.legacy_sync_keep_version(c_system, c_table, v_id, v_plan->>'fingerprint', p_record, p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(c_system, c_table, v_plan, p_record, p_sync_run_id);
    return v_plan - 'customers' - 'facts';
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_SORTING_WASH','CORRECT_LEGACY_SORTING_WASH','ADOPT_LEGACY_SORTING_WASH');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_r := v_plan->'resolved';
  v_action := v_plan->>'action';

  if v_action in ('ADOPT','ADOPT_AND_UPDATE') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'SORTING_WASH_TO_RUN', 'public.sorting_wash_runs',
      (v_plan#>>'{target,wash_run_id}')::uuid, v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted_from', v_plan#>>'{target,source_application}', 'warnings', v_plan->'warnings'));
    insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application, correlation_id)
    values ('ADOPT_LEGACY_SORTING_WASH', 'sorting_wash_runs', v_plan#>>'{target,wash_run_id}',
      jsonb_build_object('wash_id', v_id, 'fingerprint', v_plan->>'fingerprint'),
      'Legacy Sorting load already in V2 from the 2026-10-24 workbook import.', c_source, p_sync_run_id);
    if v_action = 'ADOPT' then
      return (v_plan - 'customers' - 'facts') || jsonb_build_object('outcome', 'ADOPTED', 'imported', true,
        'wash_run_id', v_plan#>>'{target,wash_run_id}', 'wash_code', v_plan#>>'{target,wash_code}');
    end if;
  end if;

  -- Corrections: cancel the current run first (same transaction).
  if v_action in ('UPDATE','ADOPT_AND_UPDATE') then
    select * into v_old from public.sorting_wash_runs
    where wash_run_id=(v_plan#>>'{target,wash_run_id}')::uuid for update;
    if v_old.status <> 'RECORDED' or v_old.row_version <> (v_plan#>>'{target,row_version}')::integer then
      raise exception using errcode='40001', message='The V2 wash changed during import. Retry.';
    end if;
    update public.sorting_wash_runs
    set status='CANCELLED', cancelled_at=now(), cancelled_by_auth_user_id=null,
        cancellation_reason='Corrected: the legacy Sorting row changed.',
        updated_at=now(), row_version=row_version+1,
        metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'cancelled_for_correction', true, 'cancelled_by', c_source, 'sync_run_id', p_sync_run_id)
    where wash_run_id=v_old.wash_run_id;
    v_code := v_id || '-R' || ((v_plan#>>'{target,chain_length}')::integer + 1)::text;
  else
    v_code := v_id;
  end if;

  insert into public.sorting_wash_runs(
    wash_code, business_date, shift_id, shift_code_snapshot,
    washer_id, washer_code_snapshot, washer_name_snapshot, washer_capacity_kg_snapshot,
    operator_staff_id, operator_name_snapshot,
    wash_type, started_at, registered_at, total_weight_kg, notes,
    source_application, recorded_by_auth_user_id, metadata,
    entry_mode, replaces_wash_run_id, correction_reason)
  values (
    v_code, (v_r->>'business_date')::date, (v_r->>'shift_id')::uuid, v_r->>'shift_code',
    (v_r->>'washer_id')::uuid, v_r->>'washer_code', v_r->>'washer_name', (v_r->>'washer_capacity_kg')::numeric,
    (v_r->>'operator_staff_id')::uuid, v_r->>'operator_name',
    v_r->>'wash_type', (v_r->>'started_at')::timestamptz, (v_r->>'registered_at')::timestamptz,
    (v_r->>'weight_kg')::numeric, null,
    c_source, null,
    jsonb_strip_nulls(jsonb_build_object(
      'source_wash_id', v_id,
      'legacy_type', v_r->>'legacy_type',
      'legacy_customers_text', v_r->>'legacy_customers_text',
      'shift_source', v_r->>'shift_source',
      'operator_resolution', v_r->>'operator_resolution',
      'sync_run_id', p_sync_run_id,
      'source_fingerprint', v_plan->>'fingerprint',
      'corrects_wash_code', v_old.wash_code,
      'late_entry', case when v_r->>'entry_mode'='LATE_ENTRY' then true end)),
    case when v_old.wash_run_id is not null then 'CORRECTION' else v_r->>'entry_mode' end,
    v_old.wash_run_id,
    case when v_old.wash_run_id is not null then 'The legacy Sorting row changed.'
         when v_r->>'entry_mode'='LATE_ENTRY' then 'Registered more than 60 minutes after the start in the legacy Sorting app.' end)
  returning * into v_new;

  -- Customers, then the schedule snapshot as save_sorting_wash_run_v2 does: the
  -- snapshot update fires the Production Flow link and the WASH_RECORDED event.
  for v_line in select value from jsonb_array_elements(v_plan->'customers') loop
    v_pos := v_pos + 1;
    insert into public.sorting_wash_run_customers(
      trace_code, wash_run_id, customer_id, customer_code_snapshot, customer_name_snapshot,
      wash_type_snapshot, schedule_relation, metadata)
    values (
      v_code || '-' || lpad(v_pos::text, 2, '0'), v_new.wash_run_id, (v_line->>'customer_id')::uuid,
      v_line->>'customer_code', v_line->>'customer_name', v_new.wash_type, 'UNSCHEDULED',
      jsonb_strip_nulls(jsonb_build_object(
        'trace_role', 'SORTING_WASH_CUSTOMER',
        'future_processing_link', true,
        'source_wash_item_ids', v_line->'wash_item_ids',
        'legacy_customer_id', v_line->>'legacy_customer_id',
        'legacy_kg_share', v_line->'legacy_kg_share',
        'legacy_scheduled_date', v_line->>'scheduled_for_date_raw')));

    update public.sorting_wash_run_customers wrc
    set source_schedule_version_id = nullif(v_line->>'schedule_version_id','')::uuid,
        source_schedule_day_id = nullif(v_line->>'schedule_day_id','')::uuid,
        source_schedule_product_id = nullif(v_line->>'schedule_product_id','')::uuid,
        production_order_snapshot = nullif(v_line->>'production_order','')::integer,
        schedule_relation = v_line->>'schedule_relation',
        scheduled_for_date = nullif(v_line->>'scheduled_for_date','')::date,
        scheduled_weekday_snapshot = case when v_line->>'scheduled_for_date' is not null
          then extract(isodow from (v_line->>'scheduled_for_date')::date)::smallint end,
        scheduled_weekday_name_snapshot = case when v_line->>'scheduled_for_date' is not null
          then trim(to_char((v_line->>'scheduled_for_date')::date, 'Day')) end,
        route_id_snapshot = nullif(v_line->>'route_id','')::uuid,
        route_code_snapshot = v_line->>'route_code',
        route_display_name_snapshot = v_line->>'route_display_name',
        route_color_snapshot = v_line->>'route_color'
    where wrc.wash_run_id = v_new.wash_run_id and wrc.customer_id = (v_line->>'customer_id')::uuid;
  end loop;

  if v_action = 'CREATE' then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'SORTING_WASH_TO_RUN', 'public.sorting_wash_runs', v_new.wash_run_id,
      v_plan->>'fingerprint', p_sync_run_id, jsonb_build_object('warnings', v_plan->'warnings'));
  end if;

  insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values (
    case when v_old.wash_run_id is null then 'IMPORT_LEGACY_SORTING_WASH' else 'CORRECT_LEGACY_SORTING_WASH' end,
    'sorting_wash_runs', v_new.wash_run_id::text,
    case when v_old.wash_run_id is not null then to_jsonb(v_old) end,
    to_jsonb(v_new),
    case when v_old.wash_run_id is null then 'Legacy Sorting sync.' else 'Legacy Sorting sync: the legacy row changed.' end,
    c_source, p_sync_run_id);

  return (v_plan - 'customers' - 'facts') || jsonb_build_object(
    'outcome', case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' else 'ADOPTED_AND_UPDATED' end,
    'imported', true, 'wash_run_id', v_new.wash_run_id, 'wash_code', v_new.wash_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Dispatchers for the Edge Function operations "dry_run" and "import".
--    Later sync parts add their kinds here, so the Edge Function does not
--    need a new deploy for each one.
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
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Control: ON / OFF switch every import switch; STATUS lists them.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_control(p_action text, p_changed_by text)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_action text := upper(btrim(coalesce(p_action, '')));
  v_who text := nullif(btrim(coalesce(p_changed_by, '')), '');
  s integration.legacy_sync_schedule%rowtype;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync control is not available to accounts.';
  end if;
  if v_action not in ('STATUS','ON','OFF') then
    raise exception using errcode='22023', message='Action must be STATUS, ON or OFF.';
  end if;

  if v_action in ('ON','OFF') then
    if v_who is null or length(v_who) > 200 then
      raise exception using errcode='22023', message='changed_by is required.';
    end if;
    update integration.legacy_sync_schedule
    set auto_enabled=(v_action='ON'), changed_at=now(), changed_by=v_who
    where schedule_key='FINISH_AREA';
    update integration.legacy_sync_settings
    set enabled=(v_action='ON'),
        max_entries_per_run=case when v_action='ON' then 300 else max_entries_per_run end,
        changed_at=now(), changed_by=v_who,
        note=case when v_action='ON' then 'Enabled from the Apps Script admin page.' else 'Disabled from the Apps Script admin page.' end;
  end if;

  select * into s from integration.legacy_sync_schedule where schedule_key='FINISH_AREA';
  if not found then
    raise exception using errcode='P0002', message='Legacy sync schedule is missing.';
  end if;

  return jsonb_build_object(
    'auto_enabled', s.auto_enabled,
    'imports', (select jsonb_object_agg(st.setting_key, st.enabled) from integration.legacy_sync_settings st),
    'window_days', s.window_days,
    'night_from', to_char(s.night_from, 'HH24:MI'),
    'night_until', to_char(s.night_until, 'HH24:MI'),
    'today', to_char((now() at time zone 'Europe/Dublin')::date, 'YYYY-MM-DD'),
    'date_from', to_char((now() at time zone 'Europe/Dublin')::date - (s.window_days - 1), 'YYYY-MM-DD'),
    'last_poll_at', s.last_poll_at,
    'changed_at', s.changed_at,
    'changed_by', s.changed_by,
    'open_review_items', (select count(*) from integration.legacy_sync_review_items ri where ri.status='OPEN'),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.started_at desc)
      from (
        select r.sync_run_id, r.status, r.requested_by, r.date_from, r.date_to,
               r.started_at, r.finished_at, r.summary
        from integration.legacy_sync_runs r
        where r.source_system='FINISH_AREA' and r.mode='COMMIT'
        order by r.started_at desc
        limit 8
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;
revoke all on function integration.legacy_sync_wash_current_run(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_wash_facts(uuid, boolean) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_wash(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_wash_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_wash(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_control(text, text) from public, anon, authenticated;

grant execute on function integration.legacy_sync_wash_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_wash(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_control(text, text) to service_role;

comment on function integration.legacy_sync_plan_wash(jsonb) is
  'Read-only plan of one legacy Sorting load (Sorting Area row + CentralDB WashItems): READY/ALREADY_IMPORTED/SKIPPED/BLOCKED.';
comment on function integration.legacy_sync_wash_dry_run(jsonb) is
  'Read-only dry run of 1-60 legacy Sorting loads.';
comment on function integration.legacy_sync_import_wash(uuid, jsonb) is
  'Imports one legacy Sorting load as a V2 wash (or correction), behind SORTING_WASH_IMPORT. service_role only.';

commit;
