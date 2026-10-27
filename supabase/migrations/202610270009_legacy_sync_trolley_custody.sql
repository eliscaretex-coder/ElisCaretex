-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270009_legacy_sync_trolley_custody
--
-- Third part of the nightly legacy sync (owner decisions 2026-10-27:
-- everything the legacy apps still record goes to V2, as if the team had
-- typed it in V2; trolley custody follows the legacy sheets): trolley
-- custody, from the production that fills a trolley to the Sorting intake
-- that receives it back.
-- Depends on 202610270007 (washes) and 202610270008 (MOP production), and
-- on the Finish part (FINISH_ENTRY_TO_ENTRY links).
--
-- One kind "trolley" with two record types, sent in time order:
--   * OUT: a trolley code typed on a legacy Finish entry (Finish Area
--     FinishEntries.Trolleys) or on a legacy MOP save (CentralDB
--     MopProduction.Trolleys). Key "<EntryID or WashItemID>:<trolley code>".
--     Written like assign_finish_trolley_to_flow /
--     assign_trolley_to_customer_from_production: an OPEN customer stay
--     (sent on the next distribution day), trolley IN_PRODUCTION,
--     ASSIGNED_IN_PRODUCTION, and the trolley on the V2 Finish entry
--     (finish_production_trolleys) or MOP production
--     (sorting_mop_production_trolleys).
--   * RETURN: one CentralDB TrolleyReturns row (key ReturnID), the legacy
--     Sorting trolley intake. Written like record_sorting_trolley_intake_v2:
--     the open stay is closed (CUSTOMER_MISMATCH when the customer differs,
--     or a MISSING_OUTBOUND_RECORD stay when nothing was open), trolley
--     AVAILABLE, a sorting_trolley_intakes row with its products and
--     Production Flows, TROLLEY_RECEIVED_CONTENTS/EMPTY, the trolley event,
--     presence evidence for the operator and audit rows.
--     A changed legacy row corrects the intake (revision, as
--     correct_sorting_trolley_intake); a voided row cancels it (as
--     cancel_sorting_trolley_intake). An intake already in V2 (the
--     2026-10-24 local import, matched by ClientEventID, or any intake of
--     the same trolley, day and shift within 4 hours) is adopted, not
--     written twice, and never changed by the sync except a legacy void.
--
-- Rules:
--   * business date, shift, operator, times, customer, Clothes/MOP and
--     contents are the legacy values;
--   * a Scheduled Date that is not on the customer's published schedule is
--     kept as OFF_SCHEDULE (NOT_ON_PUBLISHED_SCHEDULE), as V2 requires;
--   * a trolley still OPEN from before the sync window (the 2026-09 custody
--     inference) that legacy production fills again is closed as returned
--     before V2 tracking (RECEIVED, exception OTHER, no review). An open
--     stay from inside the window is closed REVIEW_REQUIRED (its return was
--     never recorded);
--   * records arriving out of time order never close a newer custody: an
--     OUT older than the trolley's last return is skipped, and a RETURN
--     older than the open stay is recorded on its own stay;
--   * Sunday 2026-10-25 is skipped (owner test day); rows before
--     2026-10-24 are skipped unless already linked;
--   * an unknown trolley, customer or operator, an operator marked absent
--     or moved out of Sorting, a trolley out of service or a production
--     that is not in V2 yet goes to the review queue.
--
-- New switch TROLLEY_CUSTODY_IMPORT (seeded OFF, limit 300). The Apps
-- Script control ON/OFF switches it with the others.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch and provenance roles
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('TROLLEY_CUSTODY_IMPORT', false, 300, 'migration 202610270009',
        'Seeded disabled. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE','SORTING_WASH_TO_RUN','MOP_ITEM_TO_BATCH',
     'TROLLEY_OUT_TO_STAY','TROLLEY_RETURN_TO_INTAKE')),
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
    (link_role='TROLLEY_RETURN_TO_INTAKE' and target_table='public.sorting_trolley_intakes')
  );

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- The facts of a Sorting intake that a legacy correction can change.
create or replace function integration.legacy_sync_trolley_intake_facts(p_intake_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select jsonb_build_object(
    'customer_id', i.customer_id,
    'scheduled_for_date', i.scheduled_for_date,
    'contents_status', i.contents_status,
    'products', coalesce((select jsonb_agg(p.product_code order by p.product_code)
                          from public.sorting_trolley_intake_products p
                          where p.sorting_trolley_intake_id=i.sorting_trolley_intake_id), '[]'::jsonb))
  from public.sorting_trolley_intakes i
  where i.sorting_trolley_intake_id=p_intake_id;
$$;

-- Operator checks shared with the MOP part: absent or moved out of Sorting in V2.
create or replace function integration.legacy_sync_sorting_operator_blockers(
  p_staff_id uuid, p_business_date date, p_shift_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select coalesce(jsonb_agg(b->0), '[]'::jsonb) from (
    select integration.legacy_sync_issue('OPERATOR_MARKED_ABSENT',
      format('%s is ABSENT in V2 Sorting attendance on %s.', sm.display_name, p_business_date)) as b
    from public.staff_members sm
    where sm.staff_id=p_staff_id and exists (
      select 1 from public.sorting_daily_staff_attendance a
      where a.business_date=p_business_date and a.shift_id=p_shift_id
        and a.staff_id=p_staff_id and a.attendance_status='ABSENT')
    union all
    select integration.legacy_sync_issue('OPERATOR_MOVED_TO_OTHER_AREA',
      format('%s is moved out of Sorting in V2 on %s.', sm.display_name, p_business_date))
    from public.staff_members sm
    where sm.staff_id=p_staff_id and exists (
      select 1 from public.work_sessions ws join public.areas ar on ar.area_id=ws.area_id
      where ws.work_date=p_business_date and ws.shift_id=p_shift_id and ws.staff_id=p_staff_id
        and ws.source='SORTING_AREA_TRANSFER' and ws.status<>'CANCELLED' and ar.area_code<>'SORTING')
  ) x;
$$;

-- ---------------------------------------------------------------------
-- 3. Planner, OUT: one trolley code of one legacy Finish entry or MOP save.
--
-- p_record:
-- { "record_type": "OUT", "source_record_id": "<EntryID or WashItemID>:<trolley code>",
--   "area": "FINISH" | "MOP", "source_id": "<EntryID or WashItemID>", "trolley_code": "T0012025T",
--   "customer_id": "<legacy CustomerID>", "business_date": "yyyy-mm-dd", "at": "<local time of the save>" }
-- Actions: CREATE (new stay), LINK_EXISTING (the trolley's open stay is
-- already this customer's production).
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_trolley_out(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_area text := upper(coalesce(integration.legacy_sync_text(p_record,'area'),''));
  v_src text := integration.legacy_sync_text(p_record,'source_id');
  v_code text := upper(btrim(coalesce(integration.legacy_sync_text(p_record,'trolley_code'),'')));
  v_day date := integration.legacy_sync_parse_date(integration.legacy_sync_text(p_record,'business_date'));
  v_at timestamptz := integration.legacy_sync_parse_instant(integration.legacy_sync_text(p_record,'at'));
  v_system text;
  v_table text;
  v_fp text := integration.legacy_sync_fingerprint(p_record);
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_prod_link integration.legacy_sync_record_links%rowtype;
  v_entry public.finish_production_entries%rowtype;
  v_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_business date;
  v_staff uuid;
  v_ref uuid;
  v_due date;
  v_trolley public.trolleys%rowtype;
  v_open public.trolley_customer_stays%rowtype;
  v_snapshot boolean;
  v_previous_mode text;
begin
  if v_area = 'FINISH' then
    v_system := 'FINISH_AREA'; v_table := 'FinishEntryTrolleys';
  elsif v_area = 'MOP' then
    v_system := 'CENTRALDB'; v_table := 'MopProductionTrolleys';
  else
    return jsonb_build_object('outcome','BLOCKED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
      'blockers', (integration.legacy_sync_issue('INVALID_AREA', v_area)),'warnings','[]'::jsonb);
  end if;
  if v_id is null or length(v_id) > 160 or v_src is null or v_id <> v_src || ':' || v_code then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
  end if;
  if v_code !~ '^T[0-9]{1,10}T$' then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_TROLLEY_CODE', v_code);
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system=v_system and l.source_table=v_table and l.source_record_id=v_id
    and l.link_role='TROLLEY_OUT_TO_STAY';
  if found then
    return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type','OUT','area',v_area,'source_record_id',v_id,
      'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings','[]'::jsonb,
      'target', jsonb_build_object('stay_id', v_link.target_id));
  end if;
  if v_day = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_day < integration.legacy_sync_finish_window_start() then
    return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- The production in V2 (written by the Finish or MOP part of the sync).
  if v_area = 'FINISH' then
    select * into v_prod_link from integration.legacy_sync_record_links l
    where l.source_system='FINISH_AREA' and l.source_table='FinishEntries' and l.source_record_id=v_src
      and l.link_role='FINISH_ENTRY_TO_ENTRY';
    if found then
      select e.* into v_entry from public.finish_production_entries e
      where e.entry_group_id=(select e0.entry_group_id from public.finish_production_entries e0
                              where e0.finish_production_entry_id=v_prod_link.target_id)
        and e.status='ACTIVE'
      order by e.revision_no desc limit 1;
      if v_entry.finish_production_entry_id is null then
        return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
          'skip_reason','PRODUCTION_NOT_ACTIVE','blockers','[]'::jsonb,'warnings','[]'::jsonb);
      end if;
      v_ref := v_entry.finish_production_entry_id;
      v_business := v_entry.production_business_date;
      v_staff := coalesce(v_entry.processed_by_staff_id, v_entry.recorded_by_staff_id);
      select * into v_flow from public.production_flow_items f where f.production_flow_item_id=v_entry.production_flow_item_id;
    else
      v_blockers := v_blockers || integration.legacy_sync_issue('FINISH_ENTRY_NOT_IN_V2',
        format('Finish entry %s is not in V2 yet (Finish part).', coalesce(v_src,'?')));
    end if;
  else
    select * into v_prod_link from integration.legacy_sync_record_links l
    where l.source_system='CENTRALDB' and l.source_table='MopProduction' and l.source_record_id=v_src
      and l.link_role='MOP_ITEM_TO_BATCH';
    if found then
      select * into v_batch from public.sorting_mop_production_batches mb
      where mb.mop_production_batch_id=integration.legacy_sync_mop_current_batch(v_prod_link.target_id);
      if v_batch.status is distinct from 'RECORDED' then
        return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
          'skip_reason','PRODUCTION_NOT_ACTIVE','blockers','[]'::jsonb,'warnings','[]'::jsonb);
      end if;
      v_ref := v_batch.mop_production_batch_id;
      v_business := v_batch.business_date;
      v_staff := v_batch.operator_staff_id;
      select * into v_flow from public.production_flow_items f where f.production_flow_item_id=v_batch.production_flow_item_id;
    else
      v_blockers := v_blockers || integration.legacy_sync_issue('MOP_NOT_IN_V2',
        format('MOP production of %s is not in V2 yet (MOP part).', coalesce(v_src,'?')));
    end if;
  end if;
  if v_at is null then
    v_at := (coalesce(v_business, v_day)::timestamp + time '12:00') at time zone 'Europe/Dublin';
  end if;

  -- Trolley.
  select * into v_trolley from public.trolleys t
  where upper(t.trolley_code)=v_code and t.deleted_at is null;
  if v_trolley.trolley_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_NOT_IN_V2', v_code);
  elsif not v_trolley.active or v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_OUT_OF_SERVICE',
      format('%s is %s in V2.', v_trolley.trolley_code, v_trolley.status));
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type','OUT','area',v_area,'source_record_id',v_id,
      'fingerprint',v_fp,'blockers',v_blockers,'warnings',v_warnings);
  end if;

  v_due := public.next_distribution_business_date(coalesce(v_flow.scheduled_for_date, v_business));
  if v_due < v_business then
    v_due := public.next_distribution_business_date(v_business);
    v_warnings := v_warnings || integration.legacy_sync_issue('PRODUCED_AFTER_DELIVERY_DATE',
      format('Produced %s for Scheduled Date %s.', v_business, v_flow.scheduled_for_date));
  end if;
  v_snapshot := v_flow.source_schedule_version_id is not null and v_flow.source_schedule_day_id is not null
                and v_flow.source_schedule_product_id is not null;
  if not v_snapshot then
    v_warnings := v_warnings || integration.legacy_sync_issue('NO_SCHEDULE_SNAPSHOT',
      'The Production Flow has no published schedule: the stay keeps the delivery day only.');
  end if;

  select * into v_open from public.trolley_customer_stays s
  where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc limit 1;

  -- Already the open stay of this customer's production (another entry, or typed in V2).
  if v_open.stay_id is not null and v_open.outbound_customer_id = v_flow.customer_id
     and (v_open.production_business_date = v_business
          or (v_open.production_business_date is null and v_open.sent_on = v_due)) then
    return jsonb_build_object('outcome','READY','action','LINK_EXISTING','record_type','OUT','area',v_area,
      'source_record_id',v_id,'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
      'resolved', jsonb_build_object('trolley_id', v_trolley.trolley_id, 'trolley_code', v_trolley.trolley_code,
        'stay_id', v_open.stay_id, 'production_ref', v_ref, 'customer_id', v_flow.customer_id,
        'business_date', v_business, 'staff_id', v_staff));
  end if;

  -- The trolley came back after this production (records sent out of time order).
  if exists (select 1 from public.sorting_trolley_intakes i
             where i.trolley_id=v_trolley.trolley_id and i.record_status='RECORDED' and i.arrived_at > v_at)
     or exists (select 1 from public.trolley_customer_stays s
                where s.trolley_id=v_trolley.trolley_id and s.received_on > v_business) then
    return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','TROLLEY_RETURNED_LATER','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_open.stay_id is not null
     and (v_open.production_business_date > v_business or v_open.production_recorded_at > v_at) then
    return jsonb_build_object('outcome','SKIPPED','record_type','OUT','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','NEWER_CUSTODY_IN_V2','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if v_open.stay_id is not null then
    v_previous_mode := case when v_open.sent_on < integration.legacy_sync_finish_window_start()
                            then 'CLOSE_BEFORE_TRACKING' else 'CLOSE_FOR_REVIEW' end;
    v_warnings := v_warnings || integration.legacy_sync_issue('PREVIOUS_STAY_CLOSED',
      format('%s was still open (sent %s); its return was never recorded.', v_trolley.trolley_code, v_open.sent_on));
  end if;

  return jsonb_build_object('outcome','READY','action','CREATE','record_type','OUT','area',v_area,
    'source_record_id',v_id,'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
    'resolved', jsonb_build_object('trolley_id', v_trolley.trolley_id, 'trolley_code', v_trolley.trolley_code,
      'production_ref', v_ref, 'production_flow_item_id', v_flow.production_flow_item_id,
      'customer_id', v_flow.customer_id, 'scheduled_for_date', v_flow.scheduled_for_date,
      'business_date', v_business, 'planned_delivery_on', v_due, 'at', v_at, 'staff_id', v_staff,
      'schedule_snapshot', v_snapshot,
      'previous_stay_id', v_open.stay_id, 'previous_mode', v_previous_mode));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Planner, RETURN: one CentralDB TrolleyReturns row.
--
-- p_record:
-- { "record_type": "RETURN", "source_record_id": "<ReturnID>",
--   "row": { ReturnID, TrolleyID, ReturnedAt, FromCustomerID, FromCustomerName, ReceivedBy,
--            ReceivedByUserID, Notes, LastDispatchAt, LastDispatchCustomerID, CustomerMatch,
--            CustomerSource, CreatedAt, BusinessDate, Shift, ServiceType, Content, ClientEventID,
--            ScheduledDate, Voided, VoidedAt, VoidedBy, VoidReason, CorrectedAt, CorrectedBy } }
-- Actions: CREATE, UPDATE (legacy correction), CANCEL (legacy void), ADOPT.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_trolley_return(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_system constant text := 'CENTRALDB';
  c_table constant text := 'TrolleyReturns';
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_target public.sorting_trolley_intakes%rowtype;
  v_adopt public.sorting_trolley_intakes%rowtype;
  v_voided boolean;
  v_business date;
  v_arrived timestamptz;
  v_physical date;
  v_code text;
  v_trolley public.trolleys%rowtype;
  v_shift_code text;
  v_shift public.shifts%rowtype;
  v_staff jsonb;
  v_operator uuid;
  v_cust jsonb;
  v_customer public.customers%rowtype;
  v_contents text;
  v_service text;
  v_products text[];
  v_product text;
  v_sched_raw text;
  v_sched date;
  v_relation text;
  v_off text;
  v_client text;
  v_open public.trolley_customer_stays%rowtype;
  v_custody text;
  v_tracking text;
  v_desired jsonb;
  v_current jsonb;
  v_washed boolean;
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or v_row is null then
    return jsonb_build_object('outcome','BLOCKED','record_type','RETURN','source_record_id',v_id,
      'blockers', (integration.legacy_sync_issue('INVALID_RECORD','The record must carry a TrolleyReturns row.')),
      'warnings','[]'::jsonb);
  end if;
  v_fp := integration.legacy_sync_fingerprint(v_row);
  if v_id is null or length(v_id) > 120 or integration.legacy_sync_text(v_row,'ReturnID') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system=c_system and l.source_table=c_table and l.source_record_id=v_id
    and l.link_role='TROLLEY_RETURN_TO_INTAKE';
  if found then
    select * into v_target from public.sorting_trolley_intakes i where i.sorting_trolley_intake_id=v_link.target_id;
  end if;

  -- Legacy void: cancel the V2 intake.
  v_voided := upper(coalesce(integration.legacy_sync_text(v_row,'Voided'),'')) in ('YES','Y','TRUE','1');
  if v_voided then
    if v_target.record_status = 'RECORDED' and jsonb_array_length(v_blockers) = 0 then
      return jsonb_build_object('outcome','READY','action','CANCEL','record_type','RETURN','source_record_id',v_id,
        'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings','[]'::jsonb,
        'target', jsonb_build_object('sorting_trolley_intake_id', v_target.sorting_trolley_intake_id),
        'resolved', jsonb_build_object('reason', coalesce(integration.legacy_sync_text(v_row,'VoidReason'),'Voided in the legacy Sorting app.')));
    end if;
    return jsonb_build_object('outcome', case when v_target.sorting_trolley_intake_id is not null then 'ALREADY_IMPORTED' else 'SKIPPED' end,
      'record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,'skip_reason','SOURCE_VOIDED',
      'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_row,'BusinessDate'));
  v_arrived := integration.legacy_sync_parse_instant(integration.legacy_sync_text(v_row,'ReturnedAt'));
  if v_business is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BUSINESS_DATE', integration.legacy_sync_text(v_row,'BusinessDate'));
  end if;
  if v_arrived is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_RETURNED_AT', integration.legacy_sync_text(v_row,'ReturnedAt'));
  elsif v_arrived > now() + interval '5 minutes' then
    v_blockers := v_blockers || integration.legacy_sync_issue('RETURNED_AT_IN_FUTURE', v_arrived::text);
  else
    v_physical := (v_arrived at time zone 'Europe/Dublin')::date;
  end if;

  if v_business = date '2026-10-25' and v_target.sorting_trolley_intake_id is null then
    return jsonb_build_object('outcome','SKIPPED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_business < integration.legacy_sync_finish_window_start() and v_target.sorting_trolley_intake_id is null then
    return jsonb_build_object('outcome','SKIPPED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- An intake our link points to and that was adopted is never changed (owner corrections stay).
  if v_target.sorting_trolley_intake_id is not null
     and (coalesce((v_link.link_metadata->>'adopted')::boolean,false) or v_target.record_status <> 'RECORDED') then
    return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
      'blockers','[]'::jsonb,'warnings','[]'::jsonb,
      'target', jsonb_build_object('sorting_trolley_intake_id', v_target.sorting_trolley_intake_id));
  end if;

  v_code := upper(btrim(coalesce(integration.legacy_sync_text(v_row,'TrolleyID'),'')));
  select * into v_trolley from public.trolleys t where upper(t.trolley_code)=v_code and t.deleted_at is null;
  v_shift_code := integration.legacy_sync_map_value('FINISH_AREA','SHIFT', integration.legacy_sync_text(v_row,'Shift'));
  select * into v_shift from public.shifts s where s.shift_code=v_shift_code and s.deleted_at is null;
  v_client := integration.legacy_sync_text(v_row,'ClientEventID');

  -- Not linked yet: an intake already in V2 for this scan is adopted.
  if v_target.sorting_trolley_intake_id is null and v_trolley.trolley_id is not null then
    select i.* into v_adopt
    from public.sorting_trolley_intakes i
    join public.trolley_customer_stays s on s.stay_id=i.stay_id
    where i.trolley_id=v_trolley.trolley_id
      and not exists (select 1 from integration.legacy_sync_record_links l
                      where l.link_role='TROLLEY_RETURN_TO_INTAKE' and l.target_id=i.sorting_trolley_intake_id)
      and ((v_client is not null and (s.notes like '%ClientEventID: ' || v_client || '%'
                                      or i.notes like '%ClientEventID: ' || v_client || '%'))
           or (i.record_status='RECORDED' and i.business_date=v_business and i.shift_id=v_shift.shift_id
               and i.arrived_at between v_arrived - interval '4 hours' and v_arrived + interval '4 hours'))
    order by (v_client is not null and (s.notes like '%ClientEventID: ' || v_client || '%'
                                        or i.notes like '%ClientEventID: ' || v_client || '%')) desc,
             abs(extract(epoch from i.arrived_at - v_arrived))
    limit 1;
    if v_adopt.sorting_trolley_intake_id is not null then
      return jsonb_build_object('outcome','READY','action','ADOPT','record_type','RETURN','source_record_id',v_id,
        'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings','[]'::jsonb,
        'target', jsonb_build_object('sorting_trolley_intake_id', v_adopt.sorting_trolley_intake_id,
          'matched_by', case when v_client is not null and v_adopt.arrived_at is not null
            and exists (select 1 from public.trolley_customer_stays s where s.stay_id=v_adopt.stay_id
                        and s.notes like '%ClientEventID: ' || v_client || '%') then 'CLIENT_EVENT_ID' else 'SAME_SHIFT_WITHIN_4H' end));
    end if;
  end if;

  -- Trolley, shift, customer, operator.
  if v_trolley.trolley_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_NOT_IN_V2', nullif(v_code,''));
  elsif v_target.sorting_trolley_intake_id is null and v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_OUT_OF_SERVICE',
      format('%s is %s in V2.', v_trolley.trolley_code, v_trolley.status));
  end if;
  if v_shift.shift_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_UNMAPPED', integration.legacy_sync_text(v_row,'Shift'));
  end if;
  v_cust := integration.legacy_sync_resolve_customer(integration.legacy_sync_text(v_row,'FromCustomerID'));
  v_blockers := v_blockers || coalesce(v_cust->'blockers','[]'::jsonb);
  if v_cust->>'customer_id' is not null then
    select * into v_customer from public.customers c where c.customer_id=(v_cust->>'customer_id')::uuid;
  end if;

  v_staff := integration.legacy_sync_resolve_staff(integration.legacy_sync_text(v_row,'ReceivedByUserID'),
                                                   integration.legacy_sync_text(v_row,'ReceivedBy'));
  if v_staff->>'staff_id' is null and integration.legacy_sync_text(v_row,'ReceivedByUserID') is not null then
    v_staff := integration.legacy_sync_resolve_staff(null, integration.legacy_sync_text(v_row,'ReceivedBy'));
  end if;
  v_operator := nullif(v_staff->>'staff_id','')::uuid;
  if v_operator is null then
    v_blockers := v_blockers || integration.legacy_sync_issue(
      case when integration.legacy_sync_text(v_row,'ReceivedBy') is null then 'OPERATOR_MISSING'
           when v_staff->'warnings' @> '[{"code":"PROCESSED_BY_NAME_AMBIGUOUS"}]' then 'OPERATOR_AMBIGUOUS'
           else 'OPERATOR_UNMATCHED' end,
      integration.legacy_sync_text(v_row,'ReceivedBy'));
  elsif v_shift.shift_id is not null and v_business is not null and v_target.sorting_trolley_intake_id is null then
    v_blockers := v_blockers || integration.legacy_sync_sorting_operator_blockers(v_operator, v_business, v_shift.shift_id);
  end if;

  -- Contents and products.
  v_contents := case upper(coalesce(integration.legacy_sync_text(v_row,'Content'),''))
    when 'WITH_ITEMS' then 'CONTENTS' when 'CONTENTS' then 'CONTENTS' when 'EMPTY' then 'EMPTY' end;
  if v_contents is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('CONTENT_UNMAPPED', integration.legacy_sync_text(v_row,'Content'));
  end if;
  v_service := upper(coalesce(integration.legacy_sync_text(v_row,'ServiceType'),''));
  v_products := case v_service when 'CLOTHES' then array['CLOTHES'] when 'MOP' then array['MOP']
                               when 'BOTH' then array['CLOTHES','MOP'] end;
  if v_products is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('SERVICE_TYPE_UNMAPPED', integration.legacy_sync_text(v_row,'ServiceType'));
  end if;

  -- Scheduled Date: kept when every product is published that day, else OFF_SCHEDULE.
  v_sched_raw := integration.legacy_sync_text(v_row,'ScheduledDate');
  v_sched := integration.legacy_sync_parse_date(v_sched_raw);
  if v_sched is not null and v_customer.customer_id is not null and v_products is not null and v_business is not null then
    if v_sched > v_business + 7 then
      v_warnings := v_warnings || integration.legacy_sync_issue('SCHEDULED_DATE_TOO_FAR', v_sched::text);
      v_sched := null;
    else
      foreach v_product in array v_products loop
        if not exists (
          select 1 from public.customer_schedule_versions csv
          join public.customer_schedule_days sd on sd.schedule_version_id=csv.schedule_version_id and sd.active
           and sd.production_weekday=extract(isodow from v_sched)::smallint
          join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active
          join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active and pt.deleted_at is null
           and pt.product_code=v_product
          where csv.customer_id=v_customer.customer_id and csv.status='PUBLISHED'
            and csv.effective_from<=v_sched and (csv.effective_until is null or csv.effective_until>=v_sched)) then
          v_warnings := v_warnings || integration.legacy_sync_issue('SCHEDULED_DATE_NOT_PUBLISHED',
            format('%s %s is not published on %s: recorded off schedule.', v_customer.customer_name, v_product, v_sched));
          v_sched := null;
          exit;
        end if;
      end loop;
    end if;
  elsif v_sched is null then
    v_warnings := v_warnings || integration.legacy_sync_issue('NO_SCHEDULED_DATE', v_sched_raw);
  end if;
  if v_sched is null then
    v_relation := 'OFF_SCHEDULE';
    v_off := 'NOT_ON_PUBLISHED_SCHEDULE';
  elsif v_business is not null then
    v_relation := public.sorting_schedule_relation_for_date(v_business, v_sched, true);
  end if;

  v_desired := jsonb_build_object('customer_id', v_customer.customer_id, 'scheduled_for_date', v_sched,
    'contents_status', v_contents,
    'products', (select coalesce(jsonb_agg(x order by x), '[]'::jsonb) from unnest(v_products) x));

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings);
  end if;

  -- Linked: a legacy correction corrects the intake.
  if v_target.sorting_trolley_intake_id is not null then
    v_current := integration.legacy_sync_trolley_intake_facts(v_target.sorting_trolley_intake_id);
    if v_current = v_desired then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
        'blockers','[]'::jsonb,'warnings','[]'::jsonb,
        'target', jsonb_build_object('sorting_trolley_intake_id', v_target.sorting_trolley_intake_id));
    end if;
    select exists (select 1 from public.sorting_trolley_intake_products p
                   join public.sorting_wash_run_customers wrc on wrc.production_flow_item_id=p.production_flow_item_id
                   join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED'
                   where p.sorting_trolley_intake_id=v_target.sorting_trolley_intake_id)
    into v_washed;
    if v_washed and (v_current->'products' <> v_desired->'products' or v_current->>'contents_status' <> v_contents) then
      return jsonb_build_object('outcome','BLOCKED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
        'blockers', (integration.legacy_sync_issue('INTAKE_ALREADY_WASHED',
          'The trolley was already washed in V2: Clothes/MOP and contents cannot change.')),'warnings',v_warnings);
    end if;
    return jsonb_build_object('outcome','READY','action','UPDATE','record_type','RETURN','source_record_id',v_id,
      'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
      'target', jsonb_build_object('sorting_trolley_intake_id', v_target.sorting_trolley_intake_id,
        'revision_no', v_target.revision_no, 'facts', v_current),
      'resolved', v_desired || jsonb_build_object('schedule_relation', v_relation, 'off_schedule_reason', v_off,
        'business_date', v_target.business_date));
  end if;

  -- New intake. Duplicate scan inside the 4-hour V2 window (would be refused by V2).
  if exists (select 1 from public.sorting_trolley_intakes i
             where i.trolley_id=v_trolley.trolley_id and i.business_date=v_business and i.shift_id=v_shift.shift_id
               and i.record_status <> 'CANCELLED'
               and i.arrived_at between v_arrived - interval '4 hours' and v_arrived + interval '1 minute') then
    return jsonb_build_object('outcome','BLOCKED','record_type','RETURN','source_record_id',v_id,'fingerprint',v_fp,
      'blockers', (integration.legacy_sync_issue('DUPLICATE_SCAN_WITHIN_4H', v_code)),'warnings',v_warnings);
  end if;

  select * into v_open from public.trolley_customer_stays s
  where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc limit 1;
  if v_open.stay_id is null then
    v_custody := 'NO_OPEN_STAY';
    v_tracking := 'MISSING_OUTBOUND_RECORD';
  elsif v_open.sent_on > v_physical or v_open.production_recorded_at > v_arrived
        or exists (select 1 from public.sorting_trolley_intakes i where i.trolley_id=v_trolley.trolley_id
                   and i.record_status='RECORDED' and i.arrived_at > v_arrived) then
    v_custody := 'OPEN_STAY_IS_NEWER';
    v_tracking := 'MISSING_OUTBOUND_RECORD';
    v_warnings := v_warnings || integration.legacy_sync_issue('OPEN_STAY_IS_NEWER',
      format('%s already went out again (sent %s): this return is recorded on its own stay.', v_code, v_open.sent_on));
  else
    v_custody := 'CLOSE_OPEN_STAY';
    v_tracking := case when v_open.outbound_customer_id = v_customer.customer_id then 'TRACKED_MATCH'
                       else 'TRACKED_CUSTOMER_MISMATCH' end;
  end if;

  return jsonb_build_object('outcome','READY','action','CREATE','record_type','RETURN','source_record_id',v_id,
    'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
    'resolved', v_desired || jsonb_build_object(
      'trolley_id', v_trolley.trolley_id, 'trolley_code', v_trolley.trolley_code,
      'business_date', v_business, 'physical_received_on', v_physical, 'arrived_at', v_arrived,
      'shift_id', v_shift.shift_id, 'shift_code', v_shift.shift_code, 'operator_staff_id', v_operator,
      'schedule_relation', v_relation, 'off_schedule_reason', v_off,
      'custody', v_custody, 'open_stay_id', v_open.stay_id, 'custody_tracking_status', v_tracking,
      'notes', concat_ws('; ', 'Legacy Sorting intake ' || v_id, 'ClientEventID: ' || v_client,
                         integration.legacy_sync_text(v_row,'Notes'))));
end;
$$;

create or replace function integration.legacy_sync_plan_trolley(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
begin
  case upper(coalesce(p_record->>'record_type',''))
    when 'OUT' then return integration.legacy_sync_plan_trolley_out(p_record);
    when 'RETURN' then return integration.legacy_sync_plan_trolley_return(p_record);
    else return jsonb_build_object('outcome','BLOCKED','source_record_id',p_record->>'source_record_id',
      'blockers', (integration.legacy_sync_issue('INVALID_RECORD_TYPE', p_record->>'record_type')),
      'warnings','[]'::jsonb);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Dry run: 1-60 records. Read-only. Each record is planned against the
--    current V2 state (an earlier record of the same batch is not applied).
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_trolley_dry_run(p_records jsonb)
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
    raise exception using errcode='22023', message='Send between 1 and 60 legacy trolley records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_trolley(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id'
          and o->>'record_type' is not distinct from v_plan->>'record_type') > 1
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
-- 6. Writers (used by the importer only).
-- ---------------------------------------------------------------------

-- OUT: the trolley leaves production for the customer.
create or replace function integration.legacy_sync_write_trolley_out(p_plan jsonb, p_sync_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_TROLLEY';
  v_r jsonb := p_plan->'resolved';
  v_area text := p_plan->>'area';
  v_trolley public.trolleys%rowtype;
  v_open public.trolley_customer_stays%rowtype;
  v_prev public.trolley_customer_stays%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_business date := (v_r->>'business_date')::date;
  v_staff uuid := nullif(v_r->>'staff_id','')::uuid;
  v_ref uuid := (v_r->>'production_ref')::uuid;
  v_snapshot boolean := coalesce((v_r->>'schedule_snapshot')::boolean, false);
  v_note text;
begin
  select * into v_trolley from public.trolleys where trolley_id=(v_r->>'trolley_id')::uuid for update;
  select * into v_open from public.trolley_customer_stays s
  where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc limit 1 for update;

  if p_plan->>'action' = 'LINK_EXISTING' then
    if v_open.stay_id is distinct from (v_r->>'stay_id')::uuid then
      raise exception using errcode='40001', message='The trolley custody changed during import. Retry.';
    end if;
    v_stay := v_open;
  else
    if v_open.stay_id is distinct from nullif(v_r->>'previous_stay_id','')::uuid then
      raise exception using errcode='40001', message='The trolley custody changed during import. Retry.';
    end if;
    select * into v_flow from public.production_flow_items where production_flow_item_id=(v_r->>'production_flow_item_id')::uuid;

    -- A stay left open: closed before the new one (one open stay per trolley).
    if v_open.stay_id is not null then
      v_note := case v_r->>'previous_mode'
        when 'CLOSE_BEFORE_TRACKING' then 'Closed by the legacy sync: the trolley was filled again in legacy production; its return happened before V2 tracking.'
        else 'Closed by the legacy sync: the trolley was filled again in legacy production; its return was never recorded.' end;
      update public.trolley_customer_stays
      set status=case when v_r->>'previous_mode'='CLOSE_BEFORE_TRACKING' then 'RECEIVED' else 'REVIEW_REQUIRED' end,
          received_on=greatest(v_open.sent_on, v_business),
          exception_type='OTHER',
          review_status=case when v_r->>'previous_mode'='CLOSE_BEFORE_TRACKING' then 'NOT_REQUIRED' else 'PENDING' end,
          notes=case when nullif(trim(notes),'') is null then v_note else notes||E'\n'||v_note end
      where stay_id=v_open.stay_id
      returning * into v_prev;
      insert into public.trolley_events(trolley_id, stay_id, event_type, customer_id, business_date, performed_by,
        source_application, reason, metadata)
      values (v_trolley.trolley_id, v_prev.stay_id, 'RECORD_CORRECTED', v_prev.outbound_customer_id, v_business, null,
        c_source, v_note, jsonb_build_object('closed_stay', true, 'previous_mode', v_r->>'previous_mode',
          'status', v_prev.status, 'review_status', v_prev.review_status, 'legacy_source', p_plan->>'source_record_id'));
      insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
      values ('CLOSE_STAY_BY_LEGACY_TROLLEY_ASSIGNMENT', 'trolley_customer_stays', v_prev.stay_id::text,
        to_jsonb(v_open), to_jsonb(v_prev), v_note, c_source, p_sync_run_id);
    end if;

    insert into public.trolley_customer_stays(
      trolley_id, outbound_customer_id, sent_on, status, review_status, sent_recorded_by, notes,
      production_business_date, planned_delivery_on, production_area_code, custody_start_source,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id,
      production_recorded_by, production_recorded_at)
    values (
      v_trolley.trolley_id, v_flow.customer_id, (v_r->>'planned_delivery_on')::date, 'OPEN', 'NOT_REQUIRED', v_staff,
      'Legacy ' || initcap(v_area) || ' production (legacy sync ' || (p_plan->>'source_record_id') || ').',
      case when v_snapshot then v_business end, (v_r->>'planned_delivery_on')::date, v_area, 'PRODUCTION_NEXT_DAY_INFERENCE',
      case when v_snapshot then v_flow.source_schedule_version_id end,
      case when v_snapshot then v_flow.source_schedule_day_id end,
      case when v_snapshot then v_flow.source_schedule_product_id end,
      v_staff, (v_r->>'at')::timestamptz)
    returning * into v_stay;

    update public.trolleys set status='IN_PRODUCTION', updated_by=null where trolley_id=v_trolley.trolley_id;

    insert into public.trolley_events(trolley_id, stay_id, event_type, customer_id, business_date, performed_by,
      source_application, reason, metadata)
    values (v_trolley.trolley_id, v_stay.stay_id, 'ASSIGNED_IN_PRODUCTION', v_flow.customer_id, v_business, v_staff,
      c_source, null, jsonb_build_object(
        'production_flow_item_id', v_flow.production_flow_item_id, 'scheduled_for_date', v_flow.scheduled_for_date,
        'production_business_date', v_business, 'planned_delivery_on', v_stay.planned_delivery_on,
        'production_area_code', v_area, 'product_code', v_flow.product_code,
        'custody_start_source', 'PRODUCTION_NEXT_DAY_INFERENCE', 'legacy_source', p_plan->>'source_record_id'));
  end if;

  -- The trolley on the production record, as the live screens write it.
  if v_area = 'FINISH' then
    insert into public.finish_production_trolleys(finish_production_entry_id, trolley_id, trolley_code_snapshot, stay_id)
    values (v_ref, v_trolley.trolley_id, v_trolley.trolley_code, v_stay.stay_id)
    on conflict (finish_production_entry_id, trolley_code_snapshot) do update
      set trolley_id=coalesce(public.finish_production_trolleys.trolley_id, excluded.trolley_id),
          stay_id=coalesce(public.finish_production_trolleys.stay_id, excluded.stay_id);
  else
    update public.sorting_mop_production_trolleys
    set stay_id=v_stay.stay_id, trolley_id=coalesce(trolley_id, v_trolley.trolley_id)
    where mop_production_batch_id=v_ref and upper(trolley_code_snapshot)=v_trolley.trolley_code and stay_id is null;
    if not found and not exists (select 1 from public.sorting_mop_production_trolleys
                                 where mop_production_batch_id=v_ref and upper(trolley_code_snapshot)=v_trolley.trolley_code) then
      insert into public.sorting_mop_production_trolleys(mop_production_batch_id, trolley_id, trolley_code_snapshot,
        stay_id, lifecycle_action)
      values (v_ref, v_trolley.trolley_id, v_trolley.trolley_code, v_stay.stay_id, 'LATE_REFERENCE_ONLY');
    end if;
  end if;

  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
  values (case v_area when 'FINISH' then 'FINISH_AREA' else 'CENTRALDB' end,
    case v_area when 'FINISH' then 'FinishEntryTrolleys' else 'MopProductionTrolleys' end,
    p_plan->>'source_record_id', 'TROLLEY_OUT_TO_STAY', 'public.trolley_customer_stays', v_stay.stay_id,
    p_plan->>'fingerprint', p_sync_run_id,
    jsonb_build_object('action', p_plan->>'action', 'production_ref', v_ref, 'warnings', p_plan->'warnings'));

  insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application, correlation_id)
  values (case p_plan->>'action' when 'LINK_EXISTING' then 'ADOPT_LEGACY_TROLLEY_ASSIGNMENT' else 'IMPORT_LEGACY_TROLLEY_ASSIGNMENT' end,
    'trolley_customer_stays', v_stay.stay_id::text, to_jsonb(v_stay) || jsonb_build_object('production_ref', v_ref),
    'Legacy sync: trolley ' || v_trolley.trolley_code || ' filled in legacy ' || initcap(v_area) || ' production.',
    c_source, p_sync_run_id);

  return jsonb_build_object('stay_id', v_stay.stay_id, 'previous_stay_closed', v_prev.stay_id);
end;
$$;

-- RETURN, new intake: the trolley arrives at Sorting.
create or replace function integration.legacy_sync_write_trolley_return(p_plan jsonb, p_sync_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_TROLLEY';
  v_r jsonb := p_plan->'resolved';
  v_trolley public.trolleys%rowtype;
  v_customer public.customers%rowtype;
  v_open public.trolley_customer_stays%rowtype;
  v_before public.trolley_customer_stays%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_intake public.sorting_trolley_intakes%rowtype;
  v_operator uuid := (v_r->>'operator_staff_id')::uuid;
  v_business date := (v_r->>'business_date')::date;
  v_physical date := (v_r->>'physical_received_on')::date;
  v_sched date := nullif(v_r->>'scheduled_for_date','')::date;
  v_contents text := v_r->>'contents_status';
  v_products text[] := array(select jsonb_array_elements_text(v_r->'products') order by 1);
  v_product text;
  v_custody text := v_r->>'custody';
  v_tracking text := v_r->>'custody_tracking_status';
  v_event text;
  v_override text;
  v_snapshot record;
  v_flow_id uuid;
  v_child_id uuid;
  v_payload jsonb := '[]'::jsonb;
  v_days integer;
  v_tracked_name text;
  v_attendance integer;
begin
  select * into v_trolley from public.trolleys where trolley_id=(v_r->>'trolley_id')::uuid for update;
  select * into v_customer from public.customers where customer_id=(v_r->>'customer_id')::uuid;
  select * into v_open from public.trolley_customer_stays s
  where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  order by s.created_at desc limit 1 for update;
  if v_open.stay_id is distinct from nullif(v_r->>'open_stay_id','')::uuid then
    raise exception using errcode='40001', message='The trolley custody changed during import. Retry.';
  end if;

  -- Custody: close the open stay, or record the arrival on its own stay.
  if v_custody = 'CLOSE_OPEN_STAY' then
    v_before := v_open;
    select c.customer_name into v_tracked_name from public.customers c where c.customer_id=v_open.outbound_customer_id;
    v_days := case when v_open.sent_on is null or v_physical < v_open.sent_on then null else v_physical - v_open.sent_on end;
    update public.trolley_customer_stays
    set received_from_customer_id=v_customer.customer_id, received_on=v_physical, status='RECEIVED',
        exception_type=case when v_tracking='TRACKED_CUSTOMER_MISMATCH' then 'CUSTOMER_MISMATCH' end,
        confirmation_source='OPEN_STAY', operator_confirmed=true, review_status='NOT_REQUIRED',
        review_started_at=null, review_started_by=null, reviewed_at=null, reviewed_by=null, review_decision=null, review_notes=null,
        received_recorded_by=v_operator
    where stay_id=v_open.stay_id
    returning * into v_stay;
    v_event := case when v_tracking='TRACKED_CUSTOMER_MISMATCH' then 'CUSTOMER_MISMATCH' else 'ARRIVED_AT_SORTING' end;
  else
    insert into public.trolley_customer_stays(trolley_id, outbound_customer_id, received_from_customer_id, sent_on,
      received_on, status, exception_type, confirmation_source, operator_confirmed, review_status, received_recorded_by, notes)
    values (v_trolley.trolley_id, null, v_customer.customer_id, null, v_physical, 'RECEIVED', 'MISSING_OUTBOUND_RECORD',
      'MANUAL_SELECTION', true, 'NOT_REQUIRED', v_operator, 'Legacy Sorting intake ' || (p_plan->>'source_record_id') || '.')
    returning * into v_stay;
    v_event := 'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND';
  end if;

  -- The trolley is free again, unless it already went out after this arrival.
  if v_custody <> 'OPEN_STAY_IS_NEWER'
     and not exists (select 1 from public.sorting_trolley_intakes i where i.trolley_id=v_trolley.trolley_id
                     and i.record_status='RECORDED' and i.arrived_at > (v_r->>'arrived_at')::timestamptz) then
    update public.trolleys set status='AVAILABLE', updated_by=null where trolley_id=v_trolley.trolley_id;
  end if;
  insert into public.trolley_events(trolley_id, stay_id, event_type, customer_id, business_date, performed_by,
    source_application, reason, metadata)
  values (v_trolley.trolley_id, v_stay.stay_id, v_event, v_customer.customer_id, v_physical, v_operator, c_source, null,
    jsonb_build_object('outbound_customer_id', v_stay.outbound_customer_id, 'received_from_customer_id', v_stay.received_from_customer_id,
      'production_business_date', v_stay.production_business_date, 'planned_delivery_on', v_stay.planned_delivery_on,
      'custody_start_source', v_stay.custody_start_source, 'confirmation_source', v_stay.confirmation_source,
      'exception_type', v_stay.exception_type, 'exception_policy', 'HISTORY_ONLY',
      'legacy_source', p_plan->>'source_record_id'));

  v_override := case when v_tracking='TRACKED_CUSTOMER_MISMATCH'
    then 'Customer confirmed in the legacy Sorting app (legacy sync).' end;

  insert into public.sorting_trolley_intakes(
    stay_id, trolley_id, trolley_code_snapshot, customer_id, customer_code_snapshot, customer_name_snapshot,
    business_date, physical_received_on, shift_id, shift_code_snapshot, arrived_at,
    contents_status, product_scope, scheduled_for_date, schedule_relation,
    confirmation_source, suggestion_reason, suggested_customer_id,
    customer_override_reason, off_schedule_reason, customer_override_code, off_schedule_code,
    tracked_outbound_customer_id, tracked_outbound_customer_name_snapshot, tracked_sent_on, tracked_days_at_customer,
    custody_tracking_status, exception_type, review_status,
    operator_staff_id, recorded_by_staff_id, recorded_by_auth_user_id, notes)
  values (
    v_stay.stay_id, v_trolley.trolley_id, v_trolley.trolley_code, v_customer.customer_id, v_customer.customer_code, v_customer.customer_name,
    v_business, v_physical, (v_r->>'shift_id')::uuid, v_r->>'shift_code', (v_r->>'arrived_at')::timestamptz,
    v_contents, case when cardinality(v_products)=2 then 'BOTH' else v_products[1] end, v_sched, v_r->>'schedule_relation',
    case when v_custody='CLOSE_OPEN_STAY' then 'OPEN_STAY' else 'MANUAL_SELECTION' end,
    case when v_custody='CLOSE_OPEN_STAY' then 'OPEN_STAY' end,
    case when v_custody='CLOSE_OPEN_STAY' then v_before.outbound_customer_id end,
    v_override, nullif(v_r->>'off_schedule_reason',''), case when v_override is not null then 'OTHER' end,
    nullif(v_r->>'off_schedule_reason',''),
    v_before.outbound_customer_id, v_tracked_name, v_before.sent_on, v_days,
    v_tracking, v_stay.exception_type, v_stay.review_status,
    v_operator, null, null, v_r->>'notes')
  returning * into v_intake;

  foreach v_product in array v_products loop
    if v_sched is not null then
      select * into v_snapshot from public.sorting_schedule_product_snapshot(v_customer.customer_id, v_product, v_sched);
    else
      select null::uuid as schedule_version_id, null::uuid as schedule_day_id, null::uuid as schedule_product_id,
        null::integer as production_order, null::integer as planned_trolley_quantity, null::uuid as route_id,
        null::text as route_code, null::text as route_display_name, null::text as route_color
      into v_snapshot;
    end if;
    v_flow_id := public.ensure_production_flow_item(v_customer.customer_id, v_product, v_sched, v_business,
      v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id, v_snapshot.production_order,
      v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name, v_snapshot.route_color);
    insert into public.sorting_trolley_intake_products(sorting_trolley_intake_id, product_code, scheduled_for_date,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id, production_order_snapshot,
      planned_trolley_quantity_snapshot, route_id_snapshot, route_code_snapshot, route_display_name_snapshot,
      route_color_snapshot, production_flow_item_id)
    values (v_intake.sorting_trolley_intake_id, v_product, v_sched,
      v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id, v_snapshot.production_order,
      v_snapshot.planned_trolley_quantity, v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name,
      v_snapshot.route_color, v_flow_id)
    returning sorting_trolley_intake_product_id into v_child_id;

    perform public.append_production_flow_event(v_flow_id,
      case when v_contents='CONTENTS' then 'TROLLEY_RECEIVED_CONTENTS' else 'TROLLEY_RECEIVED_EMPTY' end,
      'INTAKE', 20, 'SORTING', v_business, v_intake.arrived_at, v_operator, null, null,
      c_source, 'sorting_trolley_intake_products', v_child_id::text,
      jsonb_build_object('sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id, 'stay_id', v_stay.stay_id,
        'trolley_id', v_trolley.trolley_id, 'trolley_code', v_trolley.trolley_code,
        'customer_id', v_customer.customer_id, 'customer_name', v_customer.customer_name,
        'contents_status', v_contents, 'product_code', v_product, 'scheduled_for_date', v_sched,
        'schedule_relation', v_intake.schedule_relation, 'planned_trolley_quantity', v_snapshot.planned_trolley_quantity,
        'route_code', v_snapshot.route_code, 'review_status', v_intake.review_status,
        'exception_type', v_intake.exception_type, 'physical_received_on', v_physical,
        'custody_tracking_status', v_tracking, 'tracked_outbound_customer_id', v_before.outbound_customer_id,
        'tracked_sent_on', v_before.sent_on, 'tracked_days_at_customer', v_days,
        'legacy_source', p_plan->>'source_record_id'));
    v_payload := v_payload || jsonb_build_array(jsonb_build_object('product_code', v_product,
      'production_flow_item_id', v_flow_id, 'planned_trolley_quantity', v_snapshot.planned_trolley_quantity,
      'route_code', v_snapshot.route_code));
  end loop;

  insert into public.trolley_events(trolley_id, stay_id, event_type, customer_id, business_date, performed_by,
    source_application, reason, metadata)
  values (v_trolley.trolley_id, v_stay.stay_id,
    case when v_contents='CONTENTS' then 'SORTING_CONTENTS_CONFIRMED' else 'SORTING_EMPTY_CONFIRMED' end,
    v_customer.customer_id, v_business, v_operator, c_source, coalesce(v_override, nullif(v_r->>'off_schedule_reason','')),
    jsonb_build_object('sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id, 'contents_status', v_contents,
      'product_scope', v_intake.product_scope, 'product_codes', to_jsonb(v_products), 'scheduled_for_date', v_sched,
      'schedule_relation', v_intake.schedule_relation, 'physical_received_on', v_physical,
      'custody_tracking_status', v_tracking, 'tracked_outbound_customer_id', v_before.outbound_customer_id,
      'tracked_sent_on', v_before.sent_on, 'tracked_days_at_customer', v_days,
      'legacy_source', p_plan->>'source_record_id'));

  -- Presence evidence, as a Sorting intake typed in V2.
  insert into public.sorting_daily_staff_attendance(business_date, shift_id, staff_id, attendance_status, absence_reason,
    notes, source, created_by_auth_user_id, updated_by_auth_user_id)
  select v_business, v_intake.shift_id, v_operator, 'PRESENT', null,
    'Presence evidence from legacy Sorting Trolley Intake ' || v_trolley.trolley_code || '.', 'SORTING_TROLLEY_INTAKE', null, null
  where not exists (select 1 from public.sorting_daily_staff_attendance a
                    where a.business_date=v_business and a.shift_id=v_intake.shift_id and a.staff_id=v_operator);
  get diagnostics v_attendance = row_count;
  if v_attendance > 0 then
    insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application, correlation_id)
    values ('SORTING_ATTENDANCE_EVIDENCE_TROLLEY_INTAKE', 'sorting_daily_staff_attendance',
      v_operator::text || ':' || v_business::text || ':' || v_intake.shift_id::text,
      jsonb_build_object('business_date', v_business, 'shift_code', v_intake.shift_code_snapshot, 'staff_id', v_operator,
        'evidence', 'TROLLEY_INTAKE', 'sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id),
      'Legacy Sorting trolley intake.', c_source, p_sync_run_id);
  end if;

  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
  values ('CENTRALDB', 'TrolleyReturns', p_plan->>'source_record_id', 'TROLLEY_RETURN_TO_INTAKE',
    'public.sorting_trolley_intakes', v_intake.sorting_trolley_intake_id, p_plan->>'fingerprint', p_sync_run_id,
    jsonb_build_object('stay_id', v_stay.stay_id, 'custody', v_custody, 'warnings', p_plan->'warnings'));

  insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values ('IMPORT_LEGACY_TROLLEY_RETURN', 'sorting_trolley_intakes', v_intake.sorting_trolley_intake_id::text,
    case when v_before.stay_id is not null then jsonb_build_object('stay', to_jsonb(v_before)) end,
    to_jsonb(v_intake) || jsonb_build_object('products', v_payload, 'stay', to_jsonb(v_stay)),
    'Legacy sync: Sorting trolley intake ' || (p_plan->>'source_record_id') || '.', c_source, p_sync_run_id);

  return jsonb_build_object('sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id, 'stay_id', v_stay.stay_id);
end;
$$;

-- RETURN, legacy correction: the intake gets a new revision (correct_sorting_trolley_intake).
-- Washes are not moved: they follow their own legacy rows (Sorting washes part).
create or replace function integration.legacy_sync_correct_trolley_return(p_plan jsonb, p_sync_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_TROLLEY';
  v_r jsonb := p_plan->'resolved';
  v_intake public.sorting_trolley_intakes%rowtype;
  v_customer public.customers%rowtype;
  v_sched date := nullif(v_r->>'scheduled_for_date','')::date;
  v_contents text := v_r->>'contents_status';
  v_products text[] := array(select jsonb_array_elements_text(v_r->'products') order by 1);
  v_product text;
  v_reason text := 'Legacy Sorting intake corrected in the legacy app (legacy sync).';
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_old_flows uuid[];
  v_flow_id uuid;
  v_snapshot record;
begin
  select * into v_intake from public.sorting_trolley_intakes
  where sorting_trolley_intake_id=(p_plan#>>'{target,sorting_trolley_intake_id}')::uuid for update;
  if v_intake.record_status <> 'RECORDED' or v_intake.revision_no <> (p_plan#>>'{target,revision_no}')::integer then
    raise exception using errcode='40001', message='The V2 trolley intake changed during import. Retry.';
  end if;
  select * into v_customer from public.customers where customer_id=(v_r->>'customer_id')::uuid;

  v_before := to_jsonb(v_intake) || jsonb_build_object('products', coalesce((select jsonb_agg(to_jsonb(p) order by p.product_code)
    from public.sorting_trolley_intake_products p where p.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id),'[]'::jsonb));
  select array_agg(distinct production_flow_item_id) into v_old_flows
  from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  delete from public.sorting_trolley_intake_products where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  update public.sorting_trolley_intakes
  set customer_id=v_customer.customer_id, customer_code_snapshot=v_customer.customer_code,
      customer_name_snapshot=v_customer.customer_name, contents_status=v_contents,
      product_scope=case when cardinality(v_products)=2 then 'BOTH' else v_products[1] end,
      scheduled_for_date=v_sched, schedule_relation=v_r->>'schedule_relation',
      off_schedule_reason=nullif(v_r->>'off_schedule_reason',''), off_schedule_code=nullif(v_r->>'off_schedule_reason',''),
      correction_reason=v_reason, corrected_at=now(), corrected_by_auth_user_id=null, revision_no=revision_no+1
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
  returning revision_no into v_revision;

  foreach v_product in array v_products loop
    if v_sched is not null then
      select * into v_snapshot from public.sorting_schedule_product_snapshot(v_customer.customer_id, v_product, v_sched);
    else
      select null::uuid as schedule_version_id, null::uuid as schedule_day_id, null::uuid as schedule_product_id,
        null::integer as production_order, null::integer as planned_trolley_quantity, null::uuid as route_id,
        null::text as route_code, null::text as route_display_name, null::text as route_color
      into v_snapshot;
    end if;
    v_flow_id := public.ensure_production_flow_item(v_customer.customer_id, v_product, v_sched, v_intake.business_date,
      v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id, v_snapshot.production_order,
      v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name, v_snapshot.route_color);
    insert into public.sorting_trolley_intake_products(sorting_trolley_intake_id, product_code, scheduled_for_date,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id, production_order_snapshot,
      planned_trolley_quantity_snapshot, route_id_snapshot, route_code_snapshot, route_display_name_snapshot,
      route_color_snapshot, production_flow_item_id)
    values (v_intake.sorting_trolley_intake_id, v_product, v_sched,
      v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id, v_snapshot.production_order,
      v_snapshot.planned_trolley_quantity, v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name,
      v_snapshot.route_color, v_flow_id);
    perform public.append_production_flow_event(v_flow_id, 'TROLLEY_INTAKE_CORRECTED', 'INTAKE', 20, 'SORTING',
      v_intake.business_date, now(), v_intake.operator_staff_id, null, null, c_source, 'sorting_trolley_intake_revisions',
      v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,
      jsonb_build_object('reason', v_reason, 'scheduled_for_date', v_sched, 'schedule_relation', v_r->>'schedule_relation',
        'product_code', v_product, 'legacy_source', p_plan->>'source_record_id'));
  end loop;
  if v_old_flows is not null then
    foreach v_flow_id in array v_old_flows loop perform public.refresh_production_flow_wash_summary(v_flow_id); end loop;
  end if;

  select to_jsonb(i) || jsonb_build_object('products', coalesce((select jsonb_agg(to_jsonb(p) order by p.product_code)
    from public.sorting_trolley_intake_products p where p.sorting_trolley_intake_id=i.sorting_trolley_intake_id),'[]'::jsonb))
  into v_after from public.sorting_trolley_intakes i where i.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  insert into public.sorting_trolley_intake_revisions(sorting_trolley_intake_id, revision_no, action_type, reason,
    before_data, after_data, changed_by_auth_user_id, changed_by_staff_id)
  values (v_intake.sorting_trolley_intake_id, v_revision, 'CORRECTED', v_reason, v_before, v_after, null, null);
  insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values ('CORRECT_LEGACY_TROLLEY_RETURN', 'sorting_trolley_intakes', v_intake.sorting_trolley_intake_id::text,
    v_before, v_after, v_reason, c_source, p_sync_run_id);
  return jsonb_build_object('sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id, 'revision_no', v_revision);
end;
$$;

-- RETURN, legacy void: the intake is cancelled (cancel_sorting_trolley_intake). Custody is kept.
create or replace function integration.legacy_sync_cancel_trolley_return(p_plan jsonb, p_sync_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_TROLLEY';
  v_intake public.sorting_trolley_intakes%rowtype;
  v_reason text := left('Voided in the legacy Sorting app: ' || (p_plan#>>'{resolved,reason}'), 500);
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_flow_id uuid;
begin
  select * into v_intake from public.sorting_trolley_intakes
  where sorting_trolley_intake_id=(p_plan#>>'{target,sorting_trolley_intake_id}')::uuid for update;
  if v_intake.record_status <> 'RECORDED' then
    raise exception using errcode='40001', message='The V2 trolley intake changed during import. Retry.';
  end if;
  v_before := to_jsonb(v_intake) || jsonb_build_object('products', coalesce((select jsonb_agg(to_jsonb(p) order by p.product_code)
    from public.sorting_trolley_intake_products p where p.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id),'[]'::jsonb));
  update public.sorting_trolley_intakes
  set record_status='CANCELLED', cancellation_reason=v_reason, cancelled_at=now(), cancelled_by_auth_user_id=null,
      revision_no=revision_no+1
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
  returning revision_no into v_revision;
  select to_jsonb(i) into v_after from public.sorting_trolley_intakes i where i.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;
  insert into public.sorting_trolley_intake_revisions(sorting_trolley_intake_id, revision_no, action_type, reason,
    before_data, after_data, changed_by_auth_user_id, changed_by_staff_id)
  values (v_intake.sorting_trolley_intake_id, v_revision, 'CANCELLED', v_reason, v_before, v_after, null, null);
  for v_flow_id in select distinct production_flow_item_id from public.sorting_trolley_intake_products
                   where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id loop
    perform public.append_production_flow_event(v_flow_id, 'TROLLEY_INTAKE_CANCELLED', 'INTAKE', 20, 'SORTING',
      v_intake.business_date, now(), v_intake.operator_staff_id, null, null, c_source, 'sorting_trolley_intake_revisions',
      v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,
      jsonb_build_object('reason', v_reason, 'trolley_code', v_intake.trolley_code_snapshot, 'customer_id', v_intake.customer_id,
        'legacy_source', p_plan->>'source_record_id'));
    perform public.refresh_production_flow_wash_summary(v_flow_id);
  end loop;
  insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values ('CANCEL_LEGACY_TROLLEY_RETURN', 'sorting_trolley_intakes', v_intake.sorting_trolley_intake_id::text,
    v_before, v_after, v_reason, c_source, p_sync_run_id);
  return jsonb_build_object('sorting_trolley_intake_id', v_intake.sorting_trolley_intake_id, 'revision_no', v_revision);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Importer: one record, one transaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_trolley(
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
  v_plan jsonb;
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_system text;
  v_table text;
  v_done integer;
  v_trolley_code text;
  v_result jsonb;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='TROLLEY_CUSTODY_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy trolley custody import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;
  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  if v_type = 'OUT' then
    v_system := case upper(coalesce(p_record->>'area','')) when 'FINISH' then 'FINISH_AREA' else 'CENTRALDB' end;
    v_table := case upper(coalesce(p_record->>'area','')) when 'FINISH' then 'FinishEntryTrolleys' else 'MopProductionTrolleys' end;
    v_trolley_code := upper(btrim(coalesce(p_record->>'trolley_code','')));
  else
    v_system := 'CENTRALDB';
    v_table := 'TrolleyReturns';
    v_trolley_code := upper(btrim(coalesce(p_record#>>'{row,TrolleyID}','')));
  end if;

  -- One trolley at a time: its custody is a chain.
  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_TROLLEY:'||v_trolley_code, 0));

  v_plan := integration.legacy_sync_plan_trolley(p_record);
  perform integration.legacy_sync_keep_version(v_system, v_table, v_id, v_plan->>'fingerprint',
    coalesce(p_record->'row', p_record), p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(v_system, v_table, v_plan, p_record, p_sync_run_id);
    return v_plan;
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_TROLLEY_ASSIGNMENT','ADOPT_LEGACY_TROLLEY_ASSIGNMENT','IMPORT_LEGACY_TROLLEY_RETURN',
                     'CORRECT_LEGACY_TROLLEY_RETURN','CANCEL_LEGACY_TROLLEY_RETURN','ADOPT_LEGACY_TROLLEY_RETURN');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  if v_type = 'OUT' then
    v_result := integration.legacy_sync_write_trolley_out(v_plan, p_sync_run_id);
    return v_plan || v_result || jsonb_build_object('imported', true,
      'outcome', case v_plan->>'action' when 'LINK_EXISTING' then 'ADOPTED' else 'IMPORTED' end);
  end if;

  case v_plan->>'action'
    when 'ADOPT' then
      insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
        target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
      values (v_system, v_table, v_id, 'TROLLEY_RETURN_TO_INTAKE', 'public.sorting_trolley_intakes',
        (v_plan#>>'{target,sorting_trolley_intake_id}')::uuid, v_plan->>'fingerprint', p_sync_run_id,
        jsonb_build_object('adopted', true, 'matched_by', v_plan#>>'{target,matched_by}'));
      insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application, correlation_id)
      values ('ADOPT_LEGACY_TROLLEY_RETURN', 'sorting_trolley_intakes', v_plan#>>'{target,sorting_trolley_intake_id}',
        jsonb_build_object('return_id', v_id, 'matched_by', v_plan#>>'{target,matched_by}', 'fingerprint', v_plan->>'fingerprint'),
        'Legacy Sorting intake already in V2.', 'LEGACY_SYNC_TROLLEY', p_sync_run_id);
      return v_plan || jsonb_build_object('outcome','ADOPTED','imported',true);
    when 'CREATE' then
      v_result := integration.legacy_sync_write_trolley_return(v_plan, p_sync_run_id);
      return v_plan || v_result || jsonb_build_object('outcome','IMPORTED','imported',true);
    when 'UPDATE' then
      v_result := integration.legacy_sync_correct_trolley_return(v_plan, p_sync_run_id);
      return v_plan || v_result || jsonb_build_object('outcome','UPDATED','imported',true);
    when 'CANCEL' then
      v_result := integration.legacy_sync_cancel_trolley_return(v_plan, p_sync_run_id);
      return v_plan || v_result || jsonb_build_object('outcome','CANCELLED','imported',true);
    else
      raise exception using errcode='22023', message=format('Unknown trolley action: %s.', v_plan->>'action');
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Dispatchers: add the kind "trolley".
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
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_trolley_intake_facts(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_sorting_operator_blockers(uuid, date, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_trolley_out(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_trolley_return(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_trolley(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_trolley_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_write_trolley_out(jsonb, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_write_trolley_return(jsonb, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_correct_trolley_return(jsonb, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_cancel_trolley_return(jsonb, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_trolley(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_trolley_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_trolley(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_trolley(jsonb) is
  'Read-only plan of one legacy trolley record (OUT: trolley code of a Finish entry or MOP save; RETURN: TrolleyReturns row).';
comment on function integration.legacy_sync_trolley_dry_run(jsonb) is
  'Read-only dry run of 1-60 legacy trolley records.';
comment on function integration.legacy_sync_import_trolley(uuid, jsonb) is
  'Imports one legacy trolley record as V2 trolley custody / Sorting intake, behind TROLLEY_CUSTODY_IMPORT. service_role only.';

commit;
