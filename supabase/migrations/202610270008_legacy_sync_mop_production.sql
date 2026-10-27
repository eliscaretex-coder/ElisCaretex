-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270008_legacy_sync_mop_production
--
-- Second part of the nightly legacy sync (owner decision 2026-10-27:
-- everything the legacy apps still record goes to V2, as if the team had
-- typed it in V2): MOP production and its ABS batch.
-- Depends on 202610270007 (Sorting washes: the MOP wash creates the
-- Production Flow that MOP production belongs to).
--
-- Source (sent by the Apps Script, one washed MOP customer per call):
--   * CentralDB MopProduction (+ MopProductionHistory): one row per MOP type
--     saved by the legacy MOP screen (WashItemID, WashID, CustomerID,
--     BusinessDate, Shift, MopModel, QtyKgDelta, QtyUnitsDelta, Trolleys,
--     ProcessedBy, ProcessedAt, ABSStatus, ABSBatchID, Status);
--   * CentralDB WashItems (+ WashItemsHistory): the washed customer row
--     (ScheduledDate), used when the wash has no V2 link yet.
-- The record key is the legacy WashItemID: V2 keeps one active MOP
-- production per Production Flow, and one legacy WashItem is one flow.
--
-- What one import writes, the same rows as save_sorting_mop_production:
--   * a sorting_mop_production_batches row (lines per MOP type, totals,
--     shift, operator, processed time, legacy trolley codes as references);
--   * a sorting_mop_reconciliations row when the legacy row was typed late;
--   * MOP_PRODUCTION_RECORDED (or _LATE_RECORDED) on the Production Flow;
--   * the ABS batch (production_flow_external_batches) once the legacy row
--     is POSTED, with ABS_BATCH_RECORDED;
--   * an audit_log row and a MOP_ITEM_TO_BATCH provenance link.
-- A changed legacy row is a V2 correction (new revision, the old one is
-- CANCELLED/CORRECTED, as correct_sorting_mop_production does). A legacy
-- cancellation cancels the V2 production. A MOP production already in V2
-- for the flow is adopted, not written twice.
--
-- Rules:
--   * shift, business date, operator and times are the legacy values;
--   * KG and Units are the legacy values, never recalculated;
--   * legacy MOP model names map to the MOP variants by their
--     legacy_values (plus the two spellings the 2026-10-23 import accepted);
--   * trolley codes are kept as references only (LATE_REFERENCE_ONLY):
--     trolley custody comes from the trolley part of the sync;
--   * entry mode LATE_RECONCILIATION when the legacy row was saved more
--     than 60 minutes after ProcessedAt, else LIVE;
--   * Sunday 2026-10-25 is skipped (owner test day); rows before
--     2026-10-24 are skipped unless already linked;
--   * an unknown customer, operator or MOP model, an operator marked absent
--     in V2 or a wash that is not in V2 yet goes to the review queue.
--
-- New switch MOP_PRODUCTION_IMPORT (seeded OFF, limit 300). The Apps Script
-- control ON/OFF switches it with the others.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch and provenance role
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('MOP_PRODUCTION_IMPORT', false, 300, 'migration 202610270008',
        'Seeded disabled. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE','SORTING_WASH_TO_RUN','MOP_ITEM_TO_BATCH')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='HOUSEHOLD_TO_REWASH_ENTRY' and target_table='public.finish_rewash_entries') or
    (link_role='REWASH_LINE_TO_LINE' and target_table='public.finish_rewash_lines') or
    (link_role='SORTING_WASH_TO_RUN' and target_table='public.sorting_wash_runs') or
    (link_role='MOP_ITEM_TO_BATCH' and target_table='public.sorting_mop_production_batches')
  );

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- Latest revision of a MOP production (a correction points back with
-- supersedes_mop_production_batch_id).
create or replace function integration.legacy_sync_mop_current_batch(p_batch_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_id uuid := p_batch_id;
  v_next uuid;
  i integer := 0;
begin
  loop
    select mb.mop_production_batch_id into v_next
    from public.sorting_mop_production_batches mb
    where mb.supersedes_mop_production_batch_id = v_id
    order by mb.revision_no desc, mb.created_at desc
    limit 1;
    exit when v_next is null or i > 50;
    v_id := v_next;
    v_next := null;
    i := i + 1;
  end loop;
  return v_id;
end;
$$;

-- Legacy MOP model name -> active MOP variant (legacy_values of the variant
-- master, plus the spellings accepted by the 2026-10-23 import).
create or replace function integration.legacy_sync_mop_variant(p_model text)
returns uuid
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  with k as (
    select upper(regexp_replace(btrim(coalesce(p_model,'')),'\s+',' ','g')) as key
  ), alias as (
    select case k.key
      when 'GREY MOP WITH WHITE STRIPE' then 'GREY_STRIPED_WHITE_MOP'
      when 'GREY MOPS WITH WHITE STRIPE' then 'GREY_STRIPED_WHITE_MOP'
      when 'SPIN MOPS' then 'SPIN_MOP'
    end as variant_code, k.key
    from k
  )
  select pv.product_variant_id
  from public.product_variants pv
  join public.product_types pt on pt.product_type_id = pv.product_type_id
   and pt.product_code = 'MOP' and pt.active and pt.deleted_at is null
  cross join alias a
  where pv.active and pv.deleted_at is null and a.key <> ''
    and (pv.variant_code = a.variant_code
         or exists (select 1 from jsonb_array_elements_text(
                      case when jsonb_typeof(pv.metadata->'legacy_values')='array'
                           then pv.metadata->'legacy_values' else '[]'::jsonb end) lv(value)
                    where upper(regexp_replace(btrim(lv.value),'\s+',' ','g')) = a.key)
         or upper(replace(pv.variant_code,'_',' ')) = a.key)
  order by (pv.variant_code = a.variant_code) desc nulls last, pv.variant_code
  limit 1;
$$;

-- Comparable facts of a V2 MOP production. p_physical keeps only the
-- quantities (used to adopt a production typed in V2).
create or replace function integration.legacy_sync_mop_facts(p_batch_id uuid, p_physical boolean)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select case when p_physical then q.physical else q.physical || q.context end
  from (
    select
      jsonb_build_object(
        'total_kg', trim_scale(mb.total_weight_kg),
        'total_units', mb.total_units,
        'lines', coalesce((
          select jsonb_agg(jsonb_build_object('v', l.variant_code_snapshot,
                   'kg', trim_scale(coalesce(l.weight_kg,0)), 'u', coalesce(l.units,0))
                 order by l.variant_code_snapshot)
          from public.sorting_mop_production_lines l
          where l.mop_production_batch_id = mb.mop_production_batch_id), '[]'::jsonb)) as physical,
      jsonb_build_object(
        'business_date', mb.business_date,
        'shift_code', mb.shift_code_snapshot,
        'operator_staff_id', mb.operator_staff_id,
        'processed_on', mb.physical_processed_on,
        'processed_time', to_char(mb.physical_processed_time, 'HH24:MI:SS'),
        'trolleys', coalesce((
          select jsonb_agg(t.trolley_code_snapshot order by t.trolley_code_snapshot)
          from public.sorting_mop_production_trolleys t
          where t.mop_production_batch_id = mb.mop_production_batch_id), '[]'::jsonb)) as context
    from public.sorting_mop_production_batches mb
    where mb.mop_production_batch_id = p_batch_id
  ) q;
$$;

-- ---------------------------------------------------------------------
-- 3. Planner: one washed MOP customer. Read-only.
--
-- p_record:
-- {
--   "source_record_id": "<WashItemID>",
--   "item":   { WashItemID, WashID, CustomerID, CustomerName, ScheduledDate, Type }  (null when not found)
--   "events": [ { MopEventID, WashItemID, WashID, CustomerID, BusinessDate, Shift, EventType,
--                 QtyKgDelta, QtyUnitsDelta, BatchNo, MopModel, MopModelID, Trolleys,
--                 ProcessedBy, ProcessedByUserID, ProcessedAt, CreatedAt,
--                 ABSStatus, ABSBatchID, ABSLoggedAt, ABSLoggedBy, Status } ]
-- }
-- Outcomes: READY (CREATE, UPDATE, ABS_ONLY, ADOPT, ADOPT_AND_UPDATE, CANCEL),
-- ALREADY_IMPORTED, SKIPPED and BLOCKED.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_mop(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'CENTRALDB';
  c_table constant text := 'MopProduction';
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_item jsonb := case when jsonb_typeof(p_record->'item')='object' then p_record->'item' end;
  v_events jsonb := case when jsonb_typeof(p_record->'events')='array' then p_record->'events' else '[]'::jsonb end;
  v_active jsonb;
  v_first jsonb;
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_target public.sorting_mop_production_batches%rowtype;
  v_target_via text;
  v_wash_id text;
  v_business date;
  v_shift_code text;
  v_shift public.shifts%rowtype;
  v_processed timestamptz;
  v_processed_local timestamp;
  v_created timestamptz;
  v_entry_mode text;
  v_staff jsonb;
  v_operator public.staff_members%rowtype;
  v_cust jsonb;
  v_customer public.customers%rowtype;
  v_scheduled date;
  v_flow public.production_flow_items%rowtype;
  v_flow_via text;
  v_wash_in_v2 boolean := false;
  v_ev jsonb;
  v_variant uuid;
  v_pv public.product_variants%rowtype;
  v_kg numeric;
  v_units numeric;
  v_lines jsonb := '[]'::jsonb;
  v_total_kg numeric := 0;
  v_total_units integer := 0;
  v_trolleys text[] := array[]::text[];
  v_code text;
  v_abs_ref text;
  v_abs_refs text[];
  v_abs_ev jsonb;
  v_abs_staff jsonb;
  v_abs_active public.production_flow_external_batches%rowtype;
  v_abs_desired jsonb;
  v_abs_change boolean := false;
  v_planned_qty integer := 0;
  v_facts jsonb;
  v_physical jsonb;
  v_target_facts jsonb;
  v_target_physical jsonb;
  v_outcome text;
  v_action text;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' then
    return jsonb_build_object('outcome','BLOCKED','source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD','The record must be an object.'));
  end if;
  if v_id is null or length(v_id) > 120 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  end if;
  if exists (select 1 from jsonb_array_elements(v_events) e
             where integration.legacy_sync_text(e.value,'WashItemID') is distinct from v_id) then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH','An event belongs to another WashItemID.');
  end if;
  v_fp := integration.legacy_sync_fingerprint(jsonb_build_object('item', v_item, 'events', v_events));

  -- Active production rows, oldest save first.
  select coalesce(jsonb_agg(e.value order by integration.legacy_sync_parse_instant(e.value->>'ProcessedAt') nulls last,
                            e.value->>'MopEventID'), '[]'::jsonb)
  into v_active
  from jsonb_array_elements(v_events) e
  where upper(coalesce(e.value->>'Status','')) = 'ACTIVE'
    and upper(coalesce(e.value->>'EventType','PRODUCTION')) = 'PRODUCTION';
  v_first := v_active->0;

  -- V2 target: our own link, else an active MOP production on the flow (resolved below).
  select * into v_link
  from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role='MOP_ITEM_TO_BATCH';
  if found then
    v_target_via := 'LINK';
    select * into v_target from public.sorting_mop_production_batches mb
    where mb.mop_production_batch_id = integration.legacy_sync_mop_current_batch(v_link.target_id);
  end if;

  -- Every legacy row cancelled: cancel the linked V2 production, else nothing to do.
  if v_first is null then
    if jsonb_array_length(v_blockers) = 0 and v_target.status = 'RECORDED' then
      return jsonb_build_object('outcome','READY','action','CANCEL','source_record_id',v_id,'fingerprint',v_fp,
        'blockers','[]'::jsonb,'warnings','[]'::jsonb,
        'target', jsonb_build_object('via', v_target_via, 'mop_production_batch_id', v_target.mop_production_batch_id,
          'production_flow_item_id', v_target.production_flow_item_id, 'revision_no', v_target.revision_no),
        'totals', jsonb_build_object('kg', 0, 'units', 0));
    end if;
    return jsonb_build_object('outcome', case when jsonb_array_length(v_blockers) > 0 then 'BLOCKED' else 'SKIPPED' end,
      'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason', case when jsonb_array_length(v_events) = 0 then 'NO_EVENTS' else 'SOURCE_CANCELLED' end,
      'blockers',v_blockers,'warnings','[]'::jsonb);
  end if;

  -- Day, shift and times: the legacy values of the first save.
  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_first,'BusinessDate'));
  v_processed := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_first,'ProcessedAt'));
  v_created := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_first,'CreatedAt'));
  if v_business is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BUSINESS_DATE', integration.legacy_sync_text(v_first,'BusinessDate'));
  end if;
  if v_processed is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_PROCESSED_AT', integration.legacy_sync_text(v_first,'ProcessedAt'));
  elsif v_processed > now() + interval '5 minutes' then
    v_blockers := v_blockers || integration.legacy_sync_issue('PROCESSED_AT_IN_FUTURE', v_processed::text);
  else
    v_processed_local := v_processed at time zone 'Europe/Dublin';
  end if;
  v_entry_mode := case when v_created is not null and v_processed is not null
                        and v_created - v_processed > interval '60 minutes' then 'LATE_RECONCILIATION' else 'LIVE' end;

  if v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_business < integration.legacy_sync_finish_window_start() and v_target_via is distinct from 'LINK' then
    return jsonb_build_object('outcome','SKIPPED','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  v_shift_code := integration.legacy_sync_map_value('FINISH_AREA','SHIFT', integration.legacy_sync_text(v_first,'Shift'));
  select * into v_shift from public.shifts s where s.shift_code=v_shift_code and s.deleted_at is null;
  if v_shift.shift_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_UNMAPPED', integration.legacy_sync_text(v_first,'Shift'));
  end if;
  if (select count(distinct concat_ws('|', e.value->>'BusinessDate', e.value->>'Shift', e.value->>'ProcessedBy', e.value->>'ProcessedAt'))
      from jsonb_array_elements(v_active) e) > 1 then
    v_warnings := v_warnings || integration.legacy_sync_issue('MULTIPLE_SAVES',
      'More than one legacy save for this customer: V2 keeps one production with the first save''s shift and operator.');
  end if;

  -- Operator: the legacy user ID (CentralDB User, matched by name by the sender), else the unique name.
  v_staff := integration.legacy_sync_resolve_staff(integration.legacy_sync_text(v_first,'ProcessedByUserID'),
                                                   integration.legacy_sync_text(v_first,'ProcessedBy'));
  if v_staff->>'staff_id' is null and integration.legacy_sync_text(v_first,'ProcessedByUserID') is not null then
    v_staff := integration.legacy_sync_resolve_staff(null, integration.legacy_sync_text(v_first,'ProcessedBy'));
  end if;
  if v_staff->>'staff_id' is null then
    v_blockers := v_blockers || integration.legacy_sync_issue(
      case when integration.legacy_sync_text(v_first,'ProcessedBy') is null then 'OPERATOR_MISSING'
           when v_staff->'warnings' @> '[{"code":"PROCESSED_BY_NAME_AMBIGUOUS"}]' then 'OPERATOR_AMBIGUOUS'
           else 'OPERATOR_UNMATCHED' end,
      concat_ws(' / legacy UserID ', integration.legacy_sync_text(v_first,'ProcessedBy'), integration.legacy_sync_text(v_first,'ProcessedByUserID')));
  else
    select * into v_operator from public.staff_members sm where sm.staff_id=(v_staff->>'staff_id')::uuid;
    if v_shift.shift_id is not null and exists (
         select 1 from public.sorting_daily_staff_attendance a
         where a.business_date=v_business and a.shift_id=v_shift.shift_id
           and a.staff_id=v_operator.staff_id and a.attendance_status='ABSENT') then
      v_blockers := v_blockers || integration.legacy_sync_issue('OPERATOR_MARKED_ABSENT',
        format('%s is ABSENT in V2 Sorting attendance on %s %s.', v_operator.display_name, v_business, v_shift_code));
    end if;
    if v_shift.shift_id is not null and exists (
         select 1 from public.work_sessions ws join public.areas ar on ar.area_id=ws.area_id
         where ws.work_date=v_business and ws.shift_id=v_shift.shift_id and ws.staff_id=v_operator.staff_id
           and ws.source='SORTING_AREA_TRANSFER' and ws.status<>'CANCELLED' and ar.area_code<>'SORTING') then
      v_blockers := v_blockers || integration.legacy_sync_issue('OPERATOR_MOVED_TO_OTHER_AREA',
        format('%s is moved out of Sorting in V2 on %s %s.', v_operator.display_name, v_business, v_shift_code));
    end if;
  end if;

  -- Customer.
  v_cust := integration.legacy_sync_resolve_customer(coalesce(integration.legacy_sync_text(v_item,'CustomerID'),
                                                              integration.legacy_sync_text(v_first,'CustomerID')));
  v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
  if v_cust->>'customer_id' is not null then
    select * into v_customer from public.customers c where c.customer_id=(v_cust->>'customer_id')::uuid;
  end if;
  if (select count(distinct e.value->>'CustomerID') from jsonb_array_elements(v_active) e) > 1 then
    v_blockers := v_blockers || integration.legacy_sync_issue('CUSTOMER_DIFFERS_BETWEEN_ROWS', v_id);
  end if;

  -- Production Flow: the V2 wash of this WashItem first, then the customer's MOP flow of the scheduled day.
  v_wash_id := coalesce(integration.legacy_sync_text(v_item,'WashID'), integration.legacy_sync_text(v_first,'WashID'));
  v_scheduled := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_item,'ScheduledDate'));
  if v_target.production_flow_item_id is not null then
    select * into v_flow from public.production_flow_items f where f.production_flow_item_id=v_target.production_flow_item_id;
    v_flow_via := 'LINKED_PRODUCTION';
  end if;
  if v_flow.production_flow_item_id is null and v_customer.customer_id is not null then
    select f.* into v_flow
    from public.sorting_wash_run_customers wrc
    join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED'
    join public.production_flow_items f on f.production_flow_item_id=wrc.production_flow_item_id
    where (wr.wash_code = v_wash_id or wr.wash_code like v_wash_id || '-R%')
      and wrc.customer_id = v_customer.customer_id and f.product_code='MOP'
    order by (wrc.metadata->'source_wash_item_ids' ? v_id) desc, wr.created_at desc
    limit 1;
    if found then v_flow_via := 'V2_WASH'; end if;
  end if;
  if v_flow.production_flow_item_id is null and v_customer.customer_id is not null and v_scheduled is not null then
    select * into v_flow from public.production_flow_items f
    where f.customer_id=v_customer.customer_id and f.product_code='MOP' and f.scheduled_for_date=v_scheduled;
    if found then v_flow_via := 'SCHEDULED_DAY'; end if;
  end if;
  select exists (select 1 from public.sorting_wash_runs wr
                 where wr.status='RECORDED' and (wr.wash_code = v_wash_id or wr.wash_code like v_wash_id || '-R%'))
  into v_wash_in_v2;
  if v_flow.production_flow_item_id is null then
    if not v_wash_in_v2 then
      v_blockers := v_blockers || integration.legacy_sync_issue('WASH_NOT_IN_V2',
        format('Wash %s is not in V2 yet (Sorting washes part).', coalesce(v_wash_id,'?')));
    elsif v_scheduled is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('NO_SCHEDULED_DATE',
        'The CentralDB WashItem was not found: no scheduled date to open the Production Flow.');
    else
      v_flow_via := 'NEW_FLOW';
      v_warnings := v_warnings || integration.legacy_sync_issue('FLOW_OPENED_BY_MOP_IMPORT',
        format('The V2 wash %s has no Production Flow link: the MOP flow of %s is opened by this import.', v_wash_id, v_scheduled));
    end if;
  elsif v_customer.customer_id is not null and v_flow.customer_id <> v_customer.customer_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('FLOW_CUSTOMER_DIFFERS', v_flow.flow_code);
  end if;
  if v_flow.source_schedule_product_id is not null then
    select coalesce(sum(req.quantity),0)::integer into v_planned_qty
    from public.customer_schedule_trolley_requirements req
    where req.owner_schedule_product_id=v_flow.source_schedule_product_id and req.active=true;
  end if;

  -- Lines: one per MOP variant, legacy KG and Units summed as recorded.
  for v_ev in select value from jsonb_array_elements(v_active) loop
    v_variant := integration.legacy_sync_mop_variant(integration.legacy_sync_text(v_ev,'MopModel'));
    if v_variant is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('MOP_MODEL_UNMAPPED', integration.legacy_sync_text(v_ev,'MopModel'));
      continue;
    end if;
    select * into v_pv from public.product_variants pv where pv.product_variant_id=v_variant;
    v_kg := coalesce(integration.legacy_sync_parse_number(integration.legacy_sync_text(v_ev,'QtyKgDelta')), 0);
    v_units := coalesce(integration.legacy_sync_parse_number(integration.legacy_sync_text(v_ev,'QtyUnitsDelta')), 0);
    if v_kg < 0 or v_units < 0 or v_units <> trunc(v_units) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_QUANTITY',
        format('%s: %s KG, %s units', integration.legacy_sync_text(v_ev,'MopEventID'), v_kg, v_units));
      continue;
    end if;
    if v_kg = 0 and v_units = 0 then
      v_warnings := v_warnings || integration.legacy_sync_issue('ZERO_QUANTITY_ROW', integration.legacy_sync_text(v_ev,'MopEventID'));
      continue;
    end if;
    v_kg := round(v_kg, 3);
    if v_flow.source_schedule_product_id is not null and not exists (
         select 1 from public.customer_schedule_product_variants spv
         where spv.schedule_product_id=v_flow.source_schedule_product_id and spv.product_variant_id=v_variant) then
      v_warnings := v_warnings || integration.legacy_sync_issue('VARIANT_NOT_IN_SCHEDULE', v_pv.display_name);
    end if;
    if exists (select 1 from jsonb_array_elements(v_lines) l where l.value->>'product_variant_id' = v_variant::text) then
      select jsonb_agg(case when l.value->>'product_variant_id' = v_variant::text
               then l.value || jsonb_build_object(
                 'weight_kg', (l.value->>'weight_kg')::numeric + v_kg,
                 'units', (l.value->>'units')::integer + v_units::integer,
                 'source_event_ids', (l.value->'source_event_ids') || to_jsonb(integration.legacy_sync_text(v_ev,'MopEventID')))
               else l.value end)
      into v_lines from jsonb_array_elements(v_lines) l;
    else
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'product_variant_id', v_variant,
        'variant_code', v_pv.variant_code,
        'variant_name', v_pv.display_name,
        'unit_weight_grams', case when coalesce(v_pv.metadata->>'unit_weight_grams',v_pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
                                  then coalesce(v_pv.metadata->>'unit_weight_grams',v_pv.metadata->>'weight_per_unit_grams')::numeric end,
        'legacy_model', integration.legacy_sync_text(v_ev,'MopModel'),
        'weight_kg', v_kg,
        'units', v_units::integer,
        'source_event_ids', jsonb_build_array(integration.legacy_sync_text(v_ev,'MopEventID'))));
    end if;
    v_total_kg := v_total_kg + v_kg;
    v_total_units := v_total_units + v_units::integer;

    foreach v_code in array coalesce(string_to_array(upper(regexp_replace(coalesce(v_ev->>'Trolleys',''),'\s','','g')), ','), array[]::text[]) loop
      continue when v_code = '';
      if v_code !~ '^T[0-9]{1,10}T$' then
        v_warnings := v_warnings || integration.legacy_sync_issue('TROLLEY_CODE_INVALID', v_code);
      elsif not v_code = any(v_trolleys) then
        v_trolleys := array_append(v_trolleys, v_code);
      end if;
    end loop;
  end loop;
  select coalesce(array_agg(x order by x), array[]::text[]) into v_trolleys from unnest(v_trolleys) x;
  if jsonb_array_length(v_lines) = 0 and jsonb_array_length(v_blockers) = 0 then
    v_blockers := v_blockers || integration.legacy_sync_issue('NO_QUANTITY', 'No legacy row has KG or Units.');
  end if;

  -- ABS batch: the legacy batch number once POSTED.
  select array_agg(distinct trunc(integration.legacy_sync_parse_number(e.value->>'ABSBatchID'))::text)
  into v_abs_refs
  from jsonb_array_elements(v_active) e
  where upper(coalesce(e.value->>'ABSStatus','')) = 'POSTED'
    and integration.legacy_sync_parse_number(e.value->>'ABSBatchID') > 0;
  if coalesce(array_length(v_abs_refs,1),0) > 1 then
    v_warnings := v_warnings || integration.legacy_sync_issue('ABS_BATCH_NUMBERS_DIFFER', array_to_string(v_abs_refs, ', '));
  end if;
  if coalesce(array_length(v_abs_refs,1),0) >= 1 then
    select e.value into v_abs_ev from jsonb_array_elements(v_active) e
    where upper(coalesce(e.value->>'ABSStatus','')) = 'POSTED' and integration.legacy_sync_parse_number(e.value->>'ABSBatchID') > 0
    order by integration.legacy_sync_parse_instant(e.value->>'ABSLoggedAt') desc nulls last limit 1;
    v_abs_ref := trunc(integration.legacy_sync_parse_number(v_abs_ev->>'ABSBatchID'))::text;
    v_abs_staff := integration.legacy_sync_resolve_staff(null, integration.legacy_sync_text(v_abs_ev,'ABSLoggedBy'));
  end if;
  if v_flow.production_flow_item_id is not null then
    select * into v_abs_active from public.production_flow_external_batches b
    where b.production_flow_item_id=v_flow.production_flow_item_id and b.external_system_code='ABS' and b.status='ACTIVE'
    order by b.recorded_at desc limit 1;
  end if;
  if coalesce(v_abs_ref, v_abs_active.batch_reference) is not null and jsonb_array_length(v_lines) > 0 then
    v_abs_desired := jsonb_build_object(
      'batch_reference', coalesce(v_abs_ref, v_abs_active.batch_reference),
      'quantity', case when v_total_kg > 0 then round(v_total_kg, 2) else v_total_units end,
      'unit_code', case when v_total_kg > 0 then 'KG' else 'UNIT' end,
      'from_legacy', v_abs_ref is not null,
      'logged_at', integration.legacy_sync_parse_instant(v_abs_ev->>'ABSLoggedAt'),
      'logged_by_staff_id', v_abs_staff->>'staff_id',
      'logged_by', integration.legacy_sync_text(v_abs_ev,'ABSLoggedBy'));
    v_abs_change := v_abs_active.production_flow_external_batch_id is null
      or v_abs_active.batch_reference is distinct from v_abs_desired->>'batch_reference'
      or v_abs_active.quantity is distinct from (v_abs_desired->>'quantity')::numeric
      or v_abs_active.unit_code is distinct from v_abs_desired->>'unit_code';
  end if;

  -- An active production already on the flow (typed in V2) is adopted.
  if v_target.mop_production_batch_id is null and v_flow.production_flow_item_id is not null then
    select * into v_target from public.sorting_mop_production_batches mb
    where mb.production_flow_item_id=v_flow.production_flow_item_id and mb.status='RECORDED';
    if found then v_target_via := 'FLOW'; end if;
  end if;
  if v_target_via = 'LINK' and v_target.status <> 'RECORDED' then
    v_blockers := v_blockers || integration.legacy_sync_issue('TARGET_NOT_ACTIVE',
      'The V2 MOP production of this legacy row was cancelled in V2.');
  end if;

  v_physical := jsonb_build_object('total_kg', trim_scale(v_total_kg), 'total_units', v_total_units,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('v', l->>'variant_code',
               'kg', trim_scale((l->>'weight_kg')::numeric), 'u', (l->>'units')::integer) order by l->>'variant_code')
             from jsonb_array_elements(v_lines) l), '[]'::jsonb));
  v_facts := v_physical || jsonb_build_object(
    'business_date', v_business, 'shift_code', v_shift_code, 'operator_staff_id', v_operator.staff_id,
    'processed_on', v_processed_local::date, 'processed_time', to_char(v_processed_local, 'HH24:MI:SS'),
    'trolleys', to_jsonb(v_trolleys));
  if v_target.mop_production_batch_id is not null then
    v_target_facts := integration.legacy_sync_mop_facts(v_target.mop_production_batch_id, false);
    v_target_physical := integration.legacy_sync_mop_facts(v_target.mop_production_batch_id, true);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    v_outcome := 'BLOCKED';
  elsif v_target.mop_production_batch_id is null then
    v_outcome := 'READY'; v_action := 'CREATE';
  elsif v_target_via = 'LINK' and v_facts = v_target_facts then
    if v_abs_change then v_outcome := 'READY'; v_action := 'ABS_ONLY'; else v_outcome := 'ALREADY_IMPORTED'; end if;
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
    'target', case when v_target.mop_production_batch_id is not null then jsonb_build_object(
      'via', v_target_via,
      'mop_production_batch_id', v_target.mop_production_batch_id,
      'revision_no', v_target.revision_no,
      'entry_mode', v_target.entry_mode,
      'facts', v_target_facts) end,
    'resolved', jsonb_build_object(
      'business_date', v_business,
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift_code,
      'operator_staff_id', v_operator.staff_id,
      'operator_name', v_operator.display_name,
      'operator_resolution', v_staff->>'resolution',
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'production_flow_item_id', v_flow.production_flow_item_id,
      'flow_code', v_flow.flow_code,
      'flow_via', v_flow_via,
      'scheduled_for_date', coalesce(v_flow.scheduled_for_date, v_scheduled),
      'wash_id', v_wash_id,
      'processed_at', v_processed,
      'processed_on', v_processed_local::date,
      'processed_time', v_processed_local::time,
      'created_at', v_created,
      'entry_mode', v_entry_mode,
      'planned_output_trolley_quantity', v_planned_qty,
      'trolley_codes', to_jsonb(v_trolleys),
      'legacy_batch_no', integration.legacy_sync_text(v_first,'BatchNo'),
      'abs', v_abs_desired,
      'abs_change', v_abs_change),
    'facts', v_facts,
    'lines', v_lines,
    'totals', jsonb_build_object('kg', v_total_kg, 'units', v_total_units));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run: 1-60 washed MOP customers. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_mop_dry_run(p_records jsonb)
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
    raise exception using errcode='22023', message='Send between 1 and 60 legacy MOP customers.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_mop(v_record));
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
    'ready_units', (select coalesce(sum((o#>>'{totals,units}')::numeric),0) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. ABS batch of a MOP production (used by the importer).
--    Writes when the wanted batch differs from the active one: a new
--    batch, or the active one SUPERSEDED by a corrected one.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_mop_write_abs(
  p_flow_id uuid,
  p_abs jsonb,
  p_staff_id uuid,
  p_business_date date,
  p_sync_run_id uuid,
  p_batch_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_MOP';
  v_old public.production_flow_external_batches%rowtype;
  v_new public.production_flow_external_batches%rowtype;
  v_staff uuid := coalesce(nullif(p_abs->>'logged_by_staff_id','')::uuid, p_staff_id);
begin
  if p_abs is null or p_abs->>'batch_reference' is null then
    return null;
  end if;
  select * into v_old from public.production_flow_external_batches b
  where b.production_flow_item_id=p_flow_id and b.external_system_code='ABS' and b.status='ACTIVE'
  order by b.recorded_at desc limit 1
  for update;
  if v_old.production_flow_external_batch_id is not null
     and v_old.batch_reference = p_abs->>'batch_reference'
     and v_old.quantity = (p_abs->>'quantity')::numeric
     and v_old.unit_code = p_abs->>'unit_code' then
    return v_old.production_flow_external_batch_id;
  end if;

  if v_old.production_flow_external_batch_id is not null then
    update public.production_flow_external_batches
    set status='SUPERSEDED', correction_reason='Legacy MOP sync: the legacy row changed.', cancelled_at=now(),
        cancelled_by_staff_id=null, cancelled_by_auth_user_id=null
    where production_flow_external_batch_id=v_old.production_flow_external_batch_id;
  end if;

  insert into public.production_flow_external_batches(
    production_flow_item_id, external_system_code, batch_reference, quantity, unit_code,
    capture_source, status, supersedes_external_batch_id, notes, correction_reason,
    integration_metadata, recorded_at, recorded_by_staff_id, recorded_by_auth_user_id)
  values (
    p_flow_id, 'ABS', p_abs->>'batch_reference', (p_abs->>'quantity')::numeric, p_abs->>'unit_code',
    'MANUAL', 'ACTIVE', v_old.production_flow_external_batch_id,
    case when (p_abs->>'from_legacy')::boolean then 'ABS batch logged in the legacy MOP app.' end,
    case when v_old.production_flow_external_batch_id is not null then 'Legacy MOP sync: the legacy row changed.' end,
    jsonb_strip_nulls(jsonb_build_object('source', c_source, 'sync_run_id', p_sync_run_id,
      'source_mop_production_batch_id', p_batch_id, 'legacy_logged_by', p_abs->>'logged_by',
      'legacy_logged_at', p_abs->>'logged_at')),
    coalesce(nullif(p_abs->>'logged_at','')::timestamptz, now()), v_staff, null)
  returning * into v_new;

  perform public.append_production_flow_event(
    p_flow_id,
    case when v_old.production_flow_external_batch_id is null then 'ABS_BATCH_RECORDED' else 'ABS_BATCH_CORRECTED' end,
    'PRODUCTION', 40, 'MOP', p_business_date, v_new.recorded_at, v_staff, v_staff, null,
    c_source, 'production_flow_external_batches', v_new.production_flow_external_batch_id::text,
    jsonb_strip_nulls(jsonb_build_object('external_system_code','ABS','batch_reference',v_new.batch_reference,
      'quantity',v_new.quantity,'unit_code',v_new.unit_code,'capture_source',v_new.capture_source,
      'old_external_batch_id', v_old.production_flow_external_batch_id,
      'attribution_source', case when p_abs->>'logged_by_staff_id' is not null then 'LEGACY_ABS_LOGGED_BY' else 'MOP_PRODUCTION_OPERATOR' end)));

  insert into public.audit_log(actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values (v_staff,
    case when v_old.production_flow_external_batch_id is null then 'IMPORT_LEGACY_MOP_ABS_BATCH' else 'CORRECT_LEGACY_MOP_ABS_BATCH' end,
    'production_flow_external_batches', v_new.production_flow_external_batch_id::text,
    case when v_old.production_flow_external_batch_id is not null then to_jsonb(v_old) end, to_jsonb(v_new),
    'Legacy MOP sync.', c_source, p_sync_run_id);
  return v_new.production_flow_external_batch_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Importer: one washed MOP customer, one transaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_mop(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'CENTRALDB';
  c_table constant text := 'MopProduction';
  c_source constant text := 'LEGACY_SYNC_MOP';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_plan jsonb;
  v_r jsonb;
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_action text;
  v_done integer;
  v_flow_id uuid;
  v_flow public.production_flow_items%rowtype;
  v_old public.sorting_mop_production_batches%rowtype;
  v_new public.sorting_mop_production_batches%rowtype;
  v_line jsonb;
  v_code text;
  v_due date;
  v_notes text;
  v_reason text;
  v_abs public.production_flow_external_batches%rowtype;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='MOP_PRODUCTION_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy MOP production import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;
  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_MOP:'||v_id, 0));

  v_plan := integration.legacy_sync_plan_mop(p_record);
  perform integration.legacy_sync_keep_version(c_system, c_table, v_id, v_plan->>'fingerprint', p_record, p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(c_system, c_table, v_plan, p_record, p_sync_run_id);
    return v_plan - 'lines' - 'facts';
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_MOP_PRODUCTION','CORRECT_LEGACY_MOP_PRODUCTION','ADOPT_LEGACY_MOP_PRODUCTION',
                     'CANCEL_LEGACY_MOP_PRODUCTION','IMPORT_LEGACY_MOP_ABS_BATCH','CORRECT_LEGACY_MOP_ABS_BATCH');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_r := v_plan->'resolved';
  v_action := v_plan->>'action';

  -- Legacy cancellation: cancel the V2 production and its ABS batch.
  if v_action = 'CANCEL' then
    select * into v_old from public.sorting_mop_production_batches
    where mop_production_batch_id=(v_plan#>>'{target,mop_production_batch_id}')::uuid for update;
    if v_old.status <> 'RECORDED' then
      raise exception using errcode='40001', message='The V2 MOP production changed during import. Retry.';
    end if;
    update public.production_flow_external_batches
    set status='CANCELLED', correction_reason='Legacy MOP sync: the legacy row was cancelled.', cancelled_at=now()
    where production_flow_item_id=v_old.production_flow_item_id and external_system_code='ABS' and status='ACTIVE';
    update public.sorting_mop_production_batches
    set status='CANCELLED', cancellation_kind='CANCELLED', cancellation_reason='Cancelled in the legacy MOP app.',
        cancelled_at=now(), cancelled_by_staff_id=null, cancelled_by_auth_user_id=null
    where mop_production_batch_id=v_old.mop_production_batch_id
    returning * into v_new;
    perform public.append_production_flow_event(
      v_new.production_flow_item_id, 'MOP_PRODUCTION_CANCELLED', 'PRODUCTION', 40, 'MOP',
      v_new.business_date, now(), v_new.operator_staff_id, null, null,
      c_source, 'sorting_mop_production_batches', v_new.mop_production_batch_id::text,
      jsonb_build_object('revision_no', v_new.revision_no, 'total_kg', v_new.total_weight_kg, 'total_units', v_new.total_units,
        'reason', 'Cancelled in the legacy MOP app.', 'returns_to_mop_queue', true));
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values ('CANCEL_LEGACY_MOP_PRODUCTION', 'sorting_mop_production_batches', v_new.mop_production_batch_id::text,
      to_jsonb(v_old), to_jsonb(v_new), 'Legacy MOP sync: every legacy row was cancelled.', c_source, p_sync_run_id);
    return (v_plan - 'lines' - 'facts') || jsonb_build_object('outcome','CANCELLED','imported',true,
      'mop_production_batch_id', v_new.mop_production_batch_id);
  end if;

  -- Adoption: link the production typed in V2.
  if v_action in ('ADOPT','ADOPT_AND_UPDATE') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'MOP_ITEM_TO_BATCH', 'public.sorting_mop_production_batches',
      (v_plan#>>'{target,mop_production_batch_id}')::uuid, v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('adopted', true, 'warnings', v_plan->'warnings'));
    insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application, correlation_id)
    values ('ADOPT_LEGACY_MOP_PRODUCTION', 'sorting_mop_production_batches', v_plan#>>'{target,mop_production_batch_id}',
      jsonb_build_object('wash_item_id', v_id, 'fingerprint', v_plan->>'fingerprint'),
      'Legacy MOP production already in V2.', c_source, p_sync_run_id);
  end if;

  if v_action in ('ADOPT','ABS_ONLY') then
    select * into v_old from public.sorting_mop_production_batches
    where mop_production_batch_id=(v_plan#>>'{target,mop_production_batch_id}')::uuid;
    perform integration.legacy_sync_mop_write_abs(v_old.production_flow_item_id, v_r->'abs', v_old.operator_staff_id,
      v_old.business_date, p_sync_run_id, v_old.mop_production_batch_id);
    return (v_plan - 'lines' - 'facts') || jsonb_build_object(
      'outcome', case v_action when 'ADOPT' then 'ADOPTED' else 'ABS_UPDATED' end, 'imported', true,
      'mop_production_batch_id', v_old.mop_production_batch_id);
  end if;

  -- Production Flow (opened here only when the V2 wash has no flow link).
  v_flow_id := nullif(v_r->>'production_flow_item_id','')::uuid;
  if v_flow_id is null then
    v_flow_id := public.ensure_production_flow_item((v_r->>'customer_id')::uuid, 'MOP',
      (v_r->>'scheduled_for_date')::date, (v_r->>'business_date')::date);
  end if;
  select * into v_flow from public.production_flow_items where production_flow_item_id=v_flow_id for update;
  v_due := public.next_distribution_business_date(coalesce(v_flow.scheduled_for_date, v_flow.opened_business_date));

  -- Corrections: the current revision is cancelled first (same transaction).
  if v_action in ('UPDATE','ADOPT_AND_UPDATE') then
    select * into v_old from public.sorting_mop_production_batches
    where mop_production_batch_id=(v_plan#>>'{target,mop_production_batch_id}')::uuid for update;
    if v_old.status <> 'RECORDED' or v_old.revision_no <> (v_plan#>>'{target,revision_no}')::integer then
      raise exception using errcode='40001', message='The V2 MOP production changed during import. Retry.';
    end if;
    v_reason := 'Legacy MOP sync: the legacy row changed.';
    update public.sorting_mop_production_batches
    set status='CANCELLED', cancellation_kind='CORRECTED', cancellation_reason=v_reason,
        cancelled_at=now(), cancelled_by_staff_id=null, cancelled_by_auth_user_id=null
    where mop_production_batch_id=v_old.mop_production_batch_id;
  end if;

  v_notes := left(concat_ws('; ',
    'Legacy MOP sync (CentralDB MopProduction)',
    'WashItem ' || v_id,
    'Wash ' || (v_r->>'wash_id'),
    'Legacy batch ' || (v_r->>'legacy_batch_no'),
    case when v_r->>'entry_mode'='LATE_RECONCILIATION' then 'Saved in the legacy app more than 60 minutes after processing' end), 1000);

  insert into public.sorting_mop_production_batches(
    production_flow_item_id, customer_id, customer_code_snapshot, customer_name_snapshot,
    business_date, shift_id, shift_code_snapshot, scheduled_for_date, delivery_due_date,
    operator_staff_id, entry_mode, physical_processed_on, physical_processed_time, physical_time_precision,
    total_weight_kg, total_units, trolley_capture_status, planned_output_trolley_quantity,
    recorded_at, recorded_by_staff_id, recorded_by_auth_user_id, notes, status,
    supersedes_mop_production_batch_id, revision_no, change_reason)
  values (
    v_flow.production_flow_item_id, v_flow.customer_id, v_flow.customer_code_snapshot, v_flow.customer_name_snapshot,
    (v_r->>'business_date')::date, (v_r->>'shift_id')::uuid, v_r->>'shift_code', v_flow.scheduled_for_date, v_due,
    (v_r->>'operator_staff_id')::uuid, coalesce(v_old.entry_mode, v_r->>'entry_mode'),
    (v_r->>'processed_on')::date, (v_r->>'processed_time')::time, 'EXACT',
    round((v_plan#>>'{totals,kg}')::numeric, 3), (v_plan#>>'{totals,units}')::integer,
    case
      when jsonb_array_length(v_r->'trolley_codes') > 0 and coalesce(v_old.entry_mode, v_r->>'entry_mode') = 'LATE_RECONCILIATION' then 'LATE_RECORDED_CODE'
      when jsonb_array_length(v_r->'trolley_codes') > 0 and (v_r->>'planned_output_trolley_quantity')::integer = 0 then 'UNPLANNED_RECORDED'
      when jsonb_array_length(v_r->'trolley_codes') > 0
           and jsonb_array_length(v_r->'trolley_codes') = (v_r->>'planned_output_trolley_quantity')::integer then 'RECORDED'
      when jsonb_array_length(v_r->'trolley_codes') > 0 then 'RECORDED_MISMATCH'
      when (v_r->>'planned_output_trolley_quantity')::integer = 0 then 'NOT_REQUIRED'
      else 'UNKNOWN_LATE_ENTRY' end,
    (v_r->>'planned_output_trolley_quantity')::integer,
    case when v_old.mop_production_batch_id is not null then now()
         else coalesce(nullif(v_r->>'created_at','')::timestamptz, (v_r->>'processed_at')::timestamptz) end,
    (v_r->>'operator_staff_id')::uuid, null, v_notes, 'RECORDED',
    v_old.mop_production_batch_id,
    case when v_old.mop_production_batch_id is not null then coalesce(v_old.revision_no,1) + 1 end,
    v_reason)
  returning * into v_new;

  for v_line in select value from jsonb_array_elements(v_plan->'lines') loop
    insert into public.sorting_mop_production_lines(
      mop_production_batch_id, product_variant_id, variant_code_snapshot, variant_name_snapshot,
      weight_kg, units, unit_weight_grams_snapshot)
    values (v_new.mop_production_batch_id, (v_line->>'product_variant_id')::uuid, v_line->>'variant_code', v_line->>'variant_name',
      nullif((v_line->>'weight_kg')::numeric, 0), nullif((v_line->>'units')::integer, 0),
      nullif(v_line->>'unit_weight_grams','')::numeric);
  end loop;

  -- Trolley codes are references: custody comes from the trolley part of the sync.
  for v_code in select value from jsonb_array_elements_text(v_r->'trolley_codes') loop
    insert into public.sorting_mop_production_trolleys(
      mop_production_batch_id, trolley_id, trolley_code_snapshot, stay_id, lifecycle_action)
    values (v_new.mop_production_batch_id,
      (select t.trolley_id from public.trolleys t where upper(t.trolley_code)=v_code and t.deleted_at is null limit 1),
      v_code, null, 'LATE_REFERENCE_ONLY');
  end loop;

  if v_old.mop_production_batch_id is null and v_new.entry_mode = 'LATE_RECONCILIATION' then
    insert into public.sorting_mop_reconciliations(
      production_flow_item_id, delivery_due_date, decision, reason, operator_staff_id,
      linked_mop_production_batch_id, recorded_by_staff_id, recorded_by_auth_user_id)
    values (v_flow.production_flow_item_id, v_due, 'PROCESSED_MISSED_ENTRY',
      'Saved in the legacy MOP app more than 60 minutes after processing.',
      v_new.operator_staff_id, v_new.mop_production_batch_id, v_new.operator_staff_id, null);
  end if;

  if v_old.mop_production_batch_id is null then
    perform public.append_production_flow_event(
      v_flow.production_flow_item_id,
      case when v_new.entry_mode='LATE_RECONCILIATION' then 'MOP_PRODUCTION_LATE_RECORDED' else 'MOP_PRODUCTION_RECORDED' end,
      'PRODUCTION', 40, 'MOP', v_new.business_date, (v_r->>'processed_at')::timestamptz,
      v_new.operator_staff_id, v_new.operator_staff_id, null,
      c_source, 'sorting_mop_production_batches', v_new.mop_production_batch_id::text,
      jsonb_build_object(
        'entry_mode', v_new.entry_mode,
        'physical_processed_on', v_new.physical_processed_on,
        'physical_processed_time', v_new.physical_processed_time,
        'physical_time_precision', v_new.physical_time_precision,
        'total_kg', v_new.total_weight_kg,
        'total_units', v_new.total_units,
        'quantity_value', case when v_new.total_weight_kg > 0 then round(v_new.total_weight_kg, 2) else v_new.total_units end,
        'quantity_unit', case when v_new.total_weight_kg > 0 then 'KG' else 'UNIT' end,
        'quantity_basis', 'MOP_PRODUCTION_REPORTED',
        'trolley_capture_status', v_new.trolley_capture_status,
        'trolley_codes', v_r->'trolley_codes',
        'planned_output_trolley_quantity', v_new.planned_output_trolley_quantity,
        'legacy_wash_item_id', v_id));
  else
    perform public.append_production_flow_event(
      v_flow.production_flow_item_id, 'MOP_PRODUCTION_CORRECTED', 'PRODUCTION', 40, 'MOP',
      v_old.business_date, now(), v_new.operator_staff_id, null, null,
      c_source, 'sorting_mop_production_batches', v_new.mop_production_batch_id::text,
      jsonb_build_object(
        'supersedes_mop_production_batch_id', v_old.mop_production_batch_id,
        'revision_no', v_new.revision_no,
        'old_total_kg', v_old.total_weight_kg, 'old_total_units', v_old.total_units,
        'total_kg', v_new.total_weight_kg, 'total_units', v_new.total_units,
        'trolley_capture_status', v_new.trolley_capture_status,
        'trolley_codes', v_r->'trolley_codes',
        'reason', v_reason));
  end if;

  if v_action = 'CREATE' then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (c_system, c_table, v_id, 'MOP_ITEM_TO_BATCH', 'public.sorting_mop_production_batches', v_new.mop_production_batch_id,
      v_plan->>'fingerprint', p_sync_run_id, jsonb_build_object('warnings', v_plan->'warnings', 'flow_via', v_r->>'flow_via'));
  end if;

  insert into public.audit_log(actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values (v_new.operator_staff_id,
    case when v_old.mop_production_batch_id is null then 'IMPORT_LEGACY_MOP_PRODUCTION' else 'CORRECT_LEGACY_MOP_PRODUCTION' end,
    'sorting_mop_production_batches', v_new.mop_production_batch_id::text,
    case when v_old.mop_production_batch_id is not null then to_jsonb(v_old) end, to_jsonb(v_new),
    coalesce(v_reason, 'Legacy MOP sync.'), c_source, p_sync_run_id);

  -- ABS batch: the legacy one once POSTED; an active one follows the corrected totals.
  perform integration.legacy_sync_mop_write_abs(v_flow.production_flow_item_id, v_r->'abs', v_new.operator_staff_id,
    v_new.business_date, p_sync_run_id, v_new.mop_production_batch_id);

  return (v_plan - 'lines' - 'facts') || jsonb_build_object(
    'outcome', case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' else 'ADOPTED_AND_UPDATED' end,
    'imported', true, 'mop_production_batch_id', v_new.mop_production_batch_id,
    'production_flow_item_id', v_flow.production_flow_item_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Dispatchers: add the kind "mop".
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
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_mop_current_batch(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_mop_variant(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_mop_facts(uuid, boolean) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_mop(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_mop_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_mop_write_abs(uuid, jsonb, uuid, date, uuid, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_mop(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_mop_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_mop(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_mop(jsonb) is
  'Read-only plan of one washed MOP customer (CentralDB MopProduction rows of one WashItemID): READY/ALREADY_IMPORTED/SKIPPED/BLOCKED.';
comment on function integration.legacy_sync_mop_dry_run(jsonb) is
  'Read-only dry run of 1-60 legacy MOP customers.';
comment on function integration.legacy_sync_import_mop(uuid, jsonb) is
  'Imports one legacy MOP production (and its ABS batch) as V2 MOP production, behind MOP_PRODUCTION_IMPORT. service_role only.';

commit;
