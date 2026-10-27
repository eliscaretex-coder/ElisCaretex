-- ElisCaretex V2 - Validation - 202610270003_legacy_sync_finish_updates_and_rewash_lines
-- Runs entirely inside one transaction and ends with ROLLBACK: nothing is kept.
-- Plain SQL assertions (pgTAP is not installed on the remote project).
-- Run as the database owner (postgres), the role the service_role RPC executes as.
-- Every failed assertion raises an exception and aborts the run.

begin;

create function pg_temp.check(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'ok - %', p_label;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Privileges, switches, maps, links, dropped functions
-- ---------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated','integration.legacy_sync_import_rewash_cell(uuid,jsonb)','execute'),
  'authenticated cannot call the ReWash importer');
select pg_temp.check(not has_function_privilege('anon','integration.legacy_sync_import_finish_entry(uuid,jsonb)','execute'),
  'anon cannot call the Finish importer');
select pg_temp.check(has_function_privilege('service_role','integration.legacy_sync_rewash_dry_run(jsonb)','execute'),
  'service_role can call the ReWash dry run');
select pg_temp.check(not has_function_privilege('service_role','integration.legacy_sync_resolve_staff(text,text)','execute'),
  'staff helper is internal');
select pg_temp.check(to_regprocedure('integration.legacy_sync_plan_household_rewash(jsonb)') is null
                     and to_regprocedure('integration.legacy_sync_import_household_rewash(uuid,jsonb)') is null,
  'the 202610270002 HOUSEHOLD functions are gone');
select pg_temp.check((select count(*)=2 from integration.legacy_sync_settings
                      where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT') and not enabled),
  'both write switches are OFF');
select pg_temp.check(integration.legacy_sync_map_value('CENTRALDB','WASH_ITEM_TYPE','OTHERS')='CLOTHES'
                     and integration.legacy_sync_map_value('FINISH_AREA','FINISH_STATUS','DONE')='ACTIVE'
                     and integration.legacy_sync_map_value('FINISH_AREA','SHIFT','Evening')='EVENING'
                     and integration.legacy_sync_map_value('FINISH_AREA','FINISH_TABLE','Table 2')='FINISH_TABLE_2',
  'owner value maps are in place');
select pg_temp.check(integration.legacy_sync_notes_reference('Imported; source group FINISH:FE-1; x', 'FE-1')
                     and integration.legacy_sync_notes_reference('Imported; source group FINISH:FE-1', 'FE-1')
                     and not integration.legacy_sync_notes_reference('Imported; source group FINISH:FE-12', 'FE-1'),
  'notes reference matches the whole EntryID only');

do $$
begin
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint)
  values ('TEST','RewashProduction','X1','REWASH_LINE_TO_LINE','public.finish_production_lines',gen_random_uuid(),'f');
  raise exception 'FAIL: ReWash line link to a Finish production line accepted';
exception when check_violation then raise notice 'ok - ReWash line link must target finish_rewash_lines';
end $$;

-- ---------------------------------------------------------------------
-- 2. Fixture: a business day inside the sync window (not 2026-10-25),
--    two customers with a published CLOTHES schedule that day and no
--    Clothes flow yet, two free ReWash cells, one staff display name.
-- ---------------------------------------------------------------------
create temporary table t_fx (day date, cust1 text, cust2 text, rw_shift1 text, rw_table1 text,
  rw_shift2 text, rw_table2 text, staff_name text, staff_id uuid) on commit drop;

do $$
declare
  v_day date;
  v_c record;
  v_found text[] := array[]::text[];
  v_cells text[];
  v_snap record;
begin
  for v_day in
    select gs::date from generate_series(current_date, integration.legacy_sync_finish_window_start(), interval '-1 day') gs
    where gs::date <> date '2026-10-25' and extract(isodow from gs) between 1 and 6
  loop
    v_found := array[]::text[];
    for v_c in
      select cu.customer_id, cu.customer_code from public.customers cu
      where cu.active and cu.deleted_at is null and cu.legacy_metadata->>'legacy_customer_id' = cu.customer_code
        and not exists (select 1 from public.production_flow_items f
                        where f.customer_id=cu.customer_id and f.product_code='CLOTHES' and f.scheduled_for_date=v_day)
      order by cu.customer_code
    loop
      begin
        select * into v_snap from public.sorting_schedule_product_snapshot(v_c.customer_id,'CLOTHES',v_day);
        v_found := v_found || v_c.customer_code;
      exception when others then null;
      end;
      exit when cardinality(v_found) = 2;
    end loop;
    select array_agg(s.code||'|'||t.code order by s.code, t.code) into v_cells
    from (values ('MORNING'),('EVENING')) s(code), (values ('FINISH_TABLE_1'),('FINISH_TABLE_2'),('FINISH_TABLE_3')) t(code)
    where not exists (select 1 from public.finish_rewash_entries e
                      where e.status='ACTIVE' and e.production_business_date=v_day
                        and e.shift_code_snapshot=s.code and e.table_code_snapshot=t.code);
    if cardinality(v_found) = 2 and coalesce(array_length(v_cells,1),0) >= 2 then
      insert into t_fx
      select v_day, v_found[1], v_found[2],
        split_part(v_cells[1],'|',1), split_part(v_cells[1],'|',2), split_part(v_cells[2],'|',1), split_part(v_cells[2],'|',2),
        sm.display_name, sm.staff_id
      from public.staff_members sm
      where sm.deleted_at is null
        and (select count(*) from public.staff_members s2 where s2.deleted_at is null
             and lower(btrim(s2.display_name))=lower(btrim(sm.display_name))) = 1
      order by sm.display_name limit 1;
      return;
    end if;
  end loop;
end $$;

select pg_temp.check((select count(*)=1 from t_fx), 'fixture day, customers, ReWash cells and staff found');

create function pg_temp.fe(p_id text, p_shift text, p_table text, p_customer text, p_kg text,
                           p_batch text, p_type text default 'CLOTHES', p_day date default null, p_units text default '0')
returns jsonb language sql as $$
  select jsonb_build_object('source_record_id', p_id,
    'entry', jsonb_build_object('EntryID', p_id, 'CreatedAt', coalesce(p_day,f.day)::text||' 10:00:00',
      'BusinessDate', coalesce(p_day,f.day)::text, 'Shift', p_shift, 'TableID', p_table, 'EntryType', 'NORMAL',
      'WashItemID', 'WI-'||p_id, 'CustomerID', p_customer, 'BatchNo', p_batch, 'QtyKg', p_kg, 'QtyUnits', p_units,
      'TotalKg', p_kg, 'Status', 'DONE', 'StaffName', f.staff_name, 'Notes', 'note '||p_id),
    'wash_item', jsonb_build_object('WashItemID', 'WI-'||p_id, 'CustomerID', p_customer,
      'ScheduledDate', coalesce(p_day,f.day)::text, 'Type', p_type))
  from t_fx f;
$$;

create function pg_temp.has_blocker(p_plan jsonb, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_plan->'blockers','[]'::jsonb)) b where b->>'code'=p_code)
$$;
create function pg_temp.has_warning(p_plan jsonb, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_plan->'warnings','[]'::jsonb)) b where b->>'code'=p_code)
$$;
create function pg_temp.footprint() returns jsonb language sql as $$
  select jsonb_build_object(
    'rewash_entries', (select count(*) from public.finish_rewash_entries),
    'rewash_lines', (select count(*) from public.finish_rewash_lines),
    'finish_entries', (select count(*) from public.finish_production_entries),
    'finish_lines', (select count(*) from public.finish_production_lines),
    'flows', (select count(*) from public.production_flow_items),
    'events', (select count(*) from public.production_flow_events),
    'audit', (select count(*) from public.audit_log),
    'links', (select count(*) from integration.legacy_sync_record_links),
    'versions', (select count(*) from integration.legacy_sync_record_versions),
    'reviews', (select count(*) from integration.legacy_sync_review_items));
$$;

-- ---------------------------------------------------------------------
-- 3. NORMAL planner: pending, skips, OTHERS, staff by name
-- ---------------------------------------------------------------------
create temporary table t_before on commit drop as select pg_temp.footprint() as fp;

select pg_temp.check((select integration.legacy_sync_plan_finish_entry(pg_temp.fe('TEST-LS-Z','Morning','Table 1',cust1,'0','TESTLS-Z'))->>'outcome' from t_fx)='PENDING_SOURCE',
  '0 kg and 0 units is PENDING_SOURCE, not blocked');
select pg_temp.check(integration.legacy_sync_plan_finish_entry(pg_temp.fe('TEST-LS-S','Morning','Table 1','X','1','TESTLS-S','CLOTHES',date '2026-10-25'))->>'skip_reason'='OWNER_TEST_DAY',
  '2026-10-25 is still the skipped test day');
select pg_temp.check(integration.legacy_sync_plan_finish_entry(pg_temp.fe('TEST-LS-W','Morning','Table 1','X','1','TESTLS-W','CLOTHES',date '2026-10-20'))->>'skip_reason'='BEFORE_SYNC_WINDOW',
  'a row before 2026-10-24 is skipped as already imported history');

create temporary table t_p1 on commit drop as
select integration.legacy_sync_plan_finish_entry(pg_temp.fe('TEST-LS-1','Morning','Table 1',cust1,'40.5','TESTLS-001','OTHERS')) as p from t_fx;
select pg_temp.check((select p->>'outcome'='READY' and p->>'action'='CREATE' from t_p1), 'OTHERS entry is READY as CREATE');
select pg_temp.check((select p#>>'{resolved,product_code}'='CLOTHES' from t_p1), 'OTHERS resolves to CLOTHES');
select pg_temp.check((select (p#>>'{resolved,processed_by_staff_id}')::uuid = f.staff_id
                             and p#>>'{resolved,processed_by_resolution}'='DISPLAY_NAME' from t_p1, t_fx f),
  'processed-by staff resolved by exact display name');
select pg_temp.check((select pg_temp.has_warning(
    integration.legacy_sync_plan_finish_entry(jsonb_set(pg_temp.fe('TEST-LS-N','Morning','Table 1',cust1,'1','TESTLS-N'),
      '{entry,StaffName}', '"Nobody Of This Name 99"')), 'PROCESSED_BY_NAME_UNMATCHED') from t_fx),
  'unknown staff name is a warning, not a blocker');

select pg_temp.check((select fp from t_before) = pg_temp.footprint(), 'planning wrote nothing');

-- ---------------------------------------------------------------------
-- 4. NORMAL importer: CREATE, ALREADY_IMPORTED, UPDATE, identity change, pending
-- ---------------------------------------------------------------------
create temporary table t_run on commit drop as
select integration.legacy_sync_start_run('FINISH_AREA','COMMIT',null,null,'validation test') as run_id;

do $$
begin
  perform integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.fe('TEST-LS-1','Morning','Table 1',(select cust1 from t_fx),'40.5','TESTLS-001'));
  raise exception 'FAIL: import ran with the switch OFF';
exception when object_not_in_prerequisite_state then raise notice 'ok - importer refuses while the switch is OFF';
end $$;

update integration.legacy_sync_settings set enabled=true, max_entries_per_run=10, changed_by='validation test', changed_at=now()
where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT');

create temporary table t_i on commit drop as
select 'create'::text as k, integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-1','Morning','Table 1',f.cust1,'40.5','TESTLS-001','OTHERS')) as res
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='IMPORTED' from t_i where k='create'), 'CREATE imports revision 1');
select pg_temp.check((select e.revision_no=1 and e.status='ACTIVE' and e.source_application='LEGACY_SYNC_FINISH'
                             and e.notes='Legacy Finish sync; source group FINISH:TEST-LS-1'
                             and e.processed_by_staff_id=f.staff_id
                      from t_i, t_fx f, public.finish_production_entries e
                      where k='create' and e.finish_production_entry_id=(res->>'finish_production_entry_id')::uuid),
  'imported entry: revision 1, ACTIVE, labelled, source named in notes, staff set');

insert into t_i select 'again', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-1','Morning','Table 1',f.cust1,'40.5','TESTLS-001','OTHERS'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ALREADY_IMPORTED' from t_i where k='again'), 'same values again is ALREADY_IMPORTED');

insert into t_i select 'notes', integration.legacy_sync_import_finish_entry(r.run_id,
  jsonb_set(pg_temp.fe('TEST-LS-1','Morning','Table 1',f.cust1,'40.5','TESTLS-001','OTHERS'), '{entry,Notes}', '"edited note"'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ALREADY_IMPORTED' from t_i where k='notes'), 'a notes-only change does not make a revision');

insert into t_i select 'update', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-1','Morning','Table 1',f.cust1,'44.25','TESTLS-001','OTHERS'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='UPDATED' and (res->>'revision_no')::int=2 from t_i where k='update'), 'changed kg is UPDATED as revision 2');
select pg_temp.check((select old.status='SUPERSEDED' and new.status='ACTIVE' and new.entry_group_id=old.entry_group_id
                             and new.supersedes_finish_production_entry_id=old.finish_production_entry_id
                      from t_i c, t_i u, public.finish_production_entries old, public.finish_production_entries new
                      where c.k='create' and u.k='update'
                        and old.finish_production_entry_id=(c.res->>'finish_production_entry_id')::uuid
                        and new.finish_production_entry_id=(u.res->>'finish_production_entry_id')::uuid),
  'revision 1 is kept as SUPERSEDED, revision 2 is ACTIVE in the same group');
select pg_temp.check((select l.quantity=44.25 from t_i u, public.finish_production_lines l
                      where u.k='update' and l.finish_production_entry_id=(u.res->>'finish_production_entry_id')::uuid and l.unit_code='KG'),
  'revision 2 carries the new kg');
select pg_temp.check((select count(*)=1 from t_i u, public.production_flow_events ev
                      where u.k='update' and ev.event_type='FINISH_PRODUCTION_CORRECTED'
                        and ev.source_entity_id=u.res->>'finish_production_entry_id'),
  'the update appends one FINISH_PRODUCTION_CORRECTED flow event');

insert into t_i select 'same2', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-1','Morning','Table 1',f.cust1,'44.25','TESTLS-001','OTHERS'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ALREADY_IMPORTED' from t_i where k='same2'), 'revision 2 values again is ALREADY_IMPORTED');

insert into t_i select 'moved', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-1','Evening','Table 1',f.cust1,'44.25','TESTLS-001','OTHERS'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='BLOCKED' and pg_temp.has_blocker(res,'SOURCE_IDENTITY_CHANGED') from t_i where k='moved'),
  'a shift change is held as SOURCE_IDENTITY_CHANGED');
select pg_temp.check((select count(*)=1 from integration.legacy_sync_review_items
                      where source_record_id='TEST-LS-1' and reason_code='SOURCE_IDENTITY_CHANGED' and status='OPEN'),
  'the identity change has an OPEN review item');

insert into t_i select 'zero', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-Z','Morning','Table 2',f.cust2,'0','TESTLS-Z'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='PENDING_SOURCE' from t_i where k='zero')
                     and not exists (select 1 from integration.legacy_sync_review_items where source_record_id='TEST-LS-Z')
                     and not exists (select 1 from integration.legacy_sync_record_links where source_record_id='TEST-LS-Z'),
  'a 0 kg entry is not imported and not sent to review');
insert into t_i select 'filled', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-Z','Morning','Table 2',f.cust2,'18.2','TESTLS-Z'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='IMPORTED' from t_i where k='filled'), 'the same entry imports once its kg is filled');

-- ---------------------------------------------------------------------
-- 5. ADOPT an entry of an earlier import that names the legacy EntryID
-- ---------------------------------------------------------------------
-- Fixture row as the 2026-10-24 workbook import wrote it (trigger skipped for the fixture only).
set local session_replication_role = replica;
insert into public.finish_production_entries(finish_production_entry_id, entry_group_id, revision_no, status,
  production_flow_item_id, customer_id, production_business_date, delivery_date, edit_cutoff_at, shift_id, shift_code_snapshot,
  station_id, table_code_snapshot, table_name_snapshot, notes, source_application, recorded_at, processed_by_staff_id,
  processed_by_name_snapshot, trolley_scan_status)
select '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a2', 1, 'ACTIVE',
  f.production_flow_item_id, f.customer_id, e.production_business_date, e.delivery_date, e.edit_cutoff_at,
  sh.shift_id, 'EVENING', st.station_id, 'FINISH_TABLE_3', st.station_name,
  'Imported from local Finish workbook; source group FINISH:TEST-LS-A', 'LOCAL_FINISH_WORKBOOK_20261024',
  e.recorded_at, e.processed_by_staff_id, e.processed_by_name_snapshot, 'UNSPECIFIED'
from t_i z
join public.finish_production_entries e on e.finish_production_entry_id=(z.res->>'finish_production_entry_id')::uuid
join public.production_flow_items f on f.production_flow_item_id=e.production_flow_item_id
join public.shifts sh on sh.shift_code='EVENING'
join public.stations st on st.station_code='FINISH_TABLE_3'
where z.k='filled';
insert into public.finish_production_lines(finish_production_entry_id, line_no, batch_reference, unit_code, quantity)
values ('00000000-0000-4000-8000-0000000000a1', 1, 'TESTLS-A', 'KG', 21.35);
set local session_replication_role = origin;

select pg_temp.check((select integration.legacy_sync_plan_finish_entry(pg_temp.fe('TEST-LS-A','Evening','Table 3',cust2,'21.35','TESTLS-A'))->>'action' from t_fx)='ADOPT',
  'same values as the workbook entry plan as ADOPT');
insert into t_i select 'adopt', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-A','Evening','Table 3',f.cust2,'26.07','TESTLS-A'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ADOPTED_AND_UPDATED' and (res->>'revision_no')::int=2 from t_i where k='adopt'),
  'different legacy kg is ADOPTED_AND_UPDATED as revision 2 (the legacy value wins)');
select pg_temp.check((select l.target_id='00000000-0000-4000-8000-0000000000a1' and l.link_metadata->>'adopted_from'='LOCAL_FINISH_WORKBOOK_20261024'
                      from integration.legacy_sync_record_links l
                      where l.source_record_id='TEST-LS-A' and l.link_role='FINISH_ENTRY_TO_ENTRY'),
  'the legacy entry is linked to the workbook entry');
select pg_temp.check((select e.status='SUPERSEDED' from public.finish_production_entries e
                      where e.finish_production_entry_id='00000000-0000-4000-8000-0000000000a1')
                     and (select l.quantity=26.07 from t_i a, public.finish_production_lines l
                          where a.k='adopt' and l.finish_production_entry_id=(a.res->>'finish_production_entry_id')::uuid),
  'the workbook row stays as SUPERSEDED; the new revision has 26.07');
insert into t_i select 'adopt2', integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-A','Evening','Table 3',f.cust2,'26.07','TESTLS-A'))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ALREADY_IMPORTED' from t_i where k='adopt2'), 'after adoption the same values are ALREADY_IMPORTED');

do $$
begin
  insert into public.finish_production_entries(entry_group_id, revision_no, status, production_flow_item_id, customer_id,
    production_business_date, delivery_date, edit_cutoff_at, shift_id, shift_code_snapshot, station_id, table_code_snapshot,
    table_name_snapshot, source_application, trolley_scan_status)
  select entry_group_id, 9, 'CANCELLED', production_flow_item_id, customer_id, production_business_date, delivery_date,
    edit_cutoff_at, shift_id, shift_code_snapshot, station_id, table_code_snapshot, table_name_snapshot,
    'LEGACY_SYNC_FINISH', trolley_scan_status
  from public.finish_production_entries where finish_production_entry_id='00000000-0000-4000-8000-0000000000a1';
  raise exception 'FAIL: LEGACY_SYNC_FINISH revision without permit accepted';
exception when insufficient_privilege then raise notice 'ok - a LEGACY_SYNC_FINISH revision without permit is refused';
end $$;

-- ---------------------------------------------------------------------
-- 6. ReWash cells
-- ---------------------------------------------------------------------
create function pg_temp.rw(p_id text, p_shift text, p_table text, p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('source_record_id', p_id,
    'entry', jsonb_build_object('EntryID', p_id, 'CreatedAt', f.day::text||' 07:30:00', 'BusinessDate', f.day::text,
      'Shift', initcap(lower(p_shift)), 'TableID', 'Table '||right(p_table,1), 'EntryType', 'HOUSEHOLD',
      'CustomerID', 'HOUSEHOLD', 'Status', 'DONE', 'StaffName', f.staff_name, 'QtyKg', '0'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('RewashLineID', p_id||'::'||lpad(n::text,3,'0'), 'EntryID', p_id,
        'LineNo', n::text, 'BusinessDate', f.day::text, 'Shift', initcap(lower(p_shift)), 'TableID', 'Table '||right(p_table,1),
        'CustomerID', l->>0, 'QtyKg', l->>1, 'QtyUnits', '0', 'Status', 'DONE') order by n), '[]'::jsonb)
      from jsonb_array_elements(p_lines) with ordinality t(l, n)))
  from t_fx f;
$$;

select pg_temp.check((select integration.legacy_sync_plan_rewash_cell(pg_temp.rw('TEST-RW-P', rw_shift1, rw_table1,
                        jsonb_build_array(jsonb_build_array(cust1,'0'))))->>'outcome' from t_fx)='PENDING_SOURCE',
  'a ReWash header whose only line is 0 kg is PENDING_SOURCE');

insert into t_i select 'rw1', integration.legacy_sync_import_rewash_cell(r.run_id, pg_temp.rw('TEST-RW-1', f.rw_shift1, f.rw_table1,
  jsonb_build_array(jsonb_build_array(f.cust1,'2.5'), jsonb_build_array(f.cust2,'1.2'), jsonb_build_array(f.cust1,'0.8'),
                    jsonb_build_array(f.cust2,'0'))))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='IMPORTED' and (res#>>'{totals,customers}')::int=2 and (res#>>'{totals,kg}')::numeric=4.5
                      from t_i where k='rw1'), 'ReWash cell imported: 2 customers, 4.5 kg');
select pg_temp.check((select l.quantity_kg=3.3 from t_i, t_fx f, public.finish_rewash_lines l join public.customers c on c.customer_id=l.customer_id
                      where k='rw1' and l.finish_rewash_entry_id=(res->>'finish_rewash_entry_id')::uuid and c.customer_code=f.cust1),
  'the same customer twice is summed into one line');
select pg_temp.check((select pg_temp.has_warning(res,'ZERO_KG_LINE_WAITING') from t_i where k='rw1'), 'the 0 kg line is left out with a warning');
select pg_temp.check((select count(*)=3 from integration.legacy_sync_record_links where link_role='REWASH_LINE_TO_LINE' and source_record_id like 'TEST-RW-1::%')
                     and (select count(*)=1 from integration.legacy_sync_record_links where link_role='HOUSEHOLD_TO_REWASH_ENTRY' and source_record_id='TEST-RW-1'),
  'header and each included source line are linked');
select pg_temp.check((select e.notes='Legacy Finish sync; source group FINISH:TEST-RW-1' and e.processed_by_staff_id=f.staff_id
                             and e.recorded_by_auth_user_id is null
                      from t_i, t_fx f, public.finish_rewash_entries e
                      where k='rw1' and e.finish_rewash_entry_id=(res->>'finish_rewash_entry_id')::uuid),
  'ReWash entry names its source and its processing staff');

insert into t_i select 'rw1b', integration.legacy_sync_import_rewash_cell(r.run_id, pg_temp.rw('TEST-RW-1', f.rw_shift1, f.rw_table1,
  jsonb_build_array(jsonb_build_array(f.cust1,'2.5'), jsonb_build_array(f.cust2,'1.2'), jsonb_build_array(f.cust1,'0.8'),
                    jsonb_build_array(f.cust2,'0'))))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ALREADY_IMPORTED' from t_i where k='rw1b'), 'same ReWash cell again is ALREADY_IMPORTED');

insert into t_i select 'rw1c', integration.legacy_sync_import_rewash_cell(r.run_id, pg_temp.rw('TEST-RW-1', f.rw_shift1, f.rw_table1,
  jsonb_build_array(jsonb_build_array(f.cust1,'2.5'), jsonb_build_array(f.cust2,'1.2'), jsonb_build_array(f.cust1,'0.8'),
                    jsonb_build_array(f.cust2,'1.9'))))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='UPDATED' and (res->>'revision_no')::int=2 and (res#>>'{totals,kg}')::numeric=6.4 from t_i where k='rw1c'),
  'a line filled in later is UPDATED as revision 2 (6.4 kg)');
select pg_temp.check((select count(*)=1 from public.finish_rewash_entries e, t_fx f
                      where e.status='ACTIVE' and e.production_business_date=f.day
                        and e.shift_code_snapshot=f.rw_shift1 and e.table_code_snapshot=f.rw_table1)
                     and (select e.status='SUPERSEDED' from t_i, public.finish_rewash_entries e
                          where k='rw1' and e.finish_rewash_entry_id=(res->>'finish_rewash_entry_id')::uuid),
  'one ACTIVE ReWash entry per cell; revision 1 kept as SUPERSEDED');

-- A cell written by an earlier import (no recorded_by) is adopted; one recorded in the V2 app is not.
insert into public.finish_rewash_entries(finish_rewash_entry_id, entry_group_id, revision_no, status, production_business_date,
  shift_id, shift_code_snapshot, station_id, table_code_snapshot, table_name_snapshot, processed_by_name_snapshot, notes)
select '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000b1', 1, 'ACTIVE', f.day,
  sh.shift_id, f.rw_shift2, st.station_id, f.rw_table2, st.station_name, 'Legacy Finish workbook',
  'Imported aggregated RewashProduction lines from local Finish workbook.'
from t_fx f join public.shifts sh on sh.shift_code=f.rw_shift2 join public.stations st on st.station_code=f.rw_table2;
insert into public.finish_rewash_lines(finish_rewash_entry_id, line_no, customer_id, customer_code_snapshot, customer_name_snapshot, quantity_kg)
select '00000000-0000-4000-8000-0000000000b1', 1, c.customer_id, c.customer_code, c.customer_name, 5
from t_fx f join public.customers c on c.customer_code=f.cust1;

insert into t_i select 'rw2', integration.legacy_sync_import_rewash_cell(r.run_id, pg_temp.rw('TEST-RW-2', f.rw_shift2, f.rw_table2,
  jsonb_build_array(jsonb_build_array(f.cust1,'5'), jsonb_build_array(f.cust2,'2'))))
from t_run r, t_fx f;
select pg_temp.check((select res->>'outcome'='ADOPTED_AND_UPDATED' and (res->>'revision_no')::int=2 from t_i where k='rw2'),
  'an earlier-import ReWash cell is adopted and updated');
select pg_temp.check((select l.target_id='00000000-0000-4000-8000-0000000000b1' from integration.legacy_sync_record_links l
                      where l.source_record_id='TEST-RW-2' and l.link_role='HOUSEHOLD_TO_REWASH_ENTRY'),
  'the HOUSEHOLD header is linked to the adopted cell');

update public.finish_rewash_entries e set recorded_by_staff_id=f.staff_id
from t_i, t_fx f where k='rw2' and e.finish_rewash_entry_id=(res->>'finish_rewash_entry_id')::uuid;
select pg_temp.check((select pg_temp.has_blocker(integration.legacy_sync_plan_rewash_cell(pg_temp.rw('TEST-RW-3', rw_shift2, rw_table2,
                        jsonb_build_array(jsonb_build_array(cust1,'1')))), 'REWASH_CELL_LINKED_TO_OTHER_SOURCE') from t_fx),
  'a second HOUSEHOLD header for a linked cell is held');

-- ---------------------------------------------------------------------
-- 7. Run limit counts writes
-- ---------------------------------------------------------------------
update integration.legacy_sync_settings set max_entries_per_run=1 where setting_key='FINISH_HISTORICAL_IMPORT';
select pg_temp.check((select integration.legacy_sync_import_finish_entry(r.run_id, pg_temp.fe('TEST-LS-L','Evening','Table 1',f.cust1,'3','TESTLS-L'))->>'outcome'
                      from t_run r, t_fx f) = 'RUN_LIMIT_REACHED',
  'the run limit counts creates, updates and adoptions');

rollback;
