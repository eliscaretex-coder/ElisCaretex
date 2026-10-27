-- ElisCaretex V2 - Validation - 202610270002_legacy_sync_household_rewash_import
-- Historical: describes the migration as applied on 2026-10-27. Superseded by
-- 202610270003 (planner outcomes and ReWash functions changed); run that validation instead.
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
-- 1. Privileges, switch, link role
-- ---------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated','integration.legacy_sync_import_household_rewash(uuid,jsonb)','execute'),
  'authenticated cannot call the ReWash importer');
select pg_temp.check(not has_function_privilege('anon','integration.legacy_sync_plan_household_rewash(jsonb)','execute'),
  'anon cannot call the ReWash planner');
select pg_temp.check(has_function_privilege('service_role','integration.legacy_sync_import_household_rewash(uuid,jsonb)','execute'),
  'service_role can call the ReWash importer');
select pg_temp.check(not has_function_privilege('service_role','integration.legacy_sync_resolve_customer(text)','execute'),
  'customer helper is internal');
select pg_temp.check((select not enabled and max_entries_per_run=3 from integration.legacy_sync_settings
                      where setting_key='FINISH_REWASH_HISTORICAL_IMPORT'), 'ReWash switch is seeded OFF with pilot limit 3');
select pg_temp.check((select not enabled from integration.legacy_sync_settings
                      where setting_key='FINISH_HISTORICAL_IMPORT'), 'NORMAL switch is still OFF');

do $$
begin
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint)
  values ('TEST','FinishEntries','X1','FINISH_ENTRY_TO_REWASH_LINE','public.finish_rewash_lines',gen_random_uuid(),'f');
  raise exception 'FAIL: ReWash line link without source_line_key accepted';
exception when check_violation then raise notice 'ok - ReWash line link needs source_line_key';
end $$;

do $$
begin
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, source_line_key, link_role,
    target_table, target_id, source_fingerprint)
  values ('TEST','FinishEntries','X1','KG:1','FINISH_ENTRY_TO_REWASH_LINE','public.finish_production_lines',gen_random_uuid(),'f');
  raise exception 'FAIL: ReWash line link to a Finish production line accepted';
exception when check_violation then raise notice 'ok - ReWash line link must target finish_rewash_lines';
end $$;

-- ---------------------------------------------------------------------
-- 2. Fixture: a recent Monday-Saturday with two free ReWash cells, and
--    two ReWash-eligible customers that resolve by legacy ID = code.
-- ---------------------------------------------------------------------
create temporary table t_day on commit drop as
select d.day, c.cells
from (
  select gs::date as day
  from generate_series(current_date - 14, current_date - 1, interval '1 day') gs
  where extract(isodow from gs) between 1 and 6
) d
cross join lateral (
  select array_agg(s.code||'|'||t.code order by s.code, t.code) as cells
  from (values ('MORNING'),('EVENING')) s(code), (values ('FINISH_TABLE_1'),('FINISH_TABLE_2'),('FINISH_TABLE_3')) t(code)
  where not exists (select 1 from public.finish_rewash_entries e
                    where e.status='ACTIVE' and e.production_business_date=d.day
                      and e.shift_code_snapshot=s.code and e.table_code_snapshot=t.code)
) c
where coalesce(array_length(c.cells,1),0) >= 2
  and (select count(*) from jsonb_array_elements(public.finish_rewash_customer_options_v1(d.day)) o
       join public.customers cu on cu.customer_id=(o->>'customer_id')::uuid
       where cu.legacy_metadata->>'legacy_customer_id' = cu.customer_code) >= 2
order by d.day desc
limit 1;

select pg_temp.check((select count(*)=1 from t_day), 'fixture day with two free ReWash cells found');

create temporary table t_fx on commit drop as
select d.day,
       split_part(d.cells[1],'|',1) as shift1, split_part(d.cells[1],'|',2) as table1,
       split_part(d.cells[2],'|',1) as shift2, split_part(d.cells[2],'|',2) as table2,
       (select max(gs)::date from generate_series(current_date - 20, current_date - 1, interval '1 day') gs
        where extract(isodow from gs) = 7 and gs::date <> date '2026-10-25') as sunday,
       c[1] as cust1, c[2] as cust2
from t_day d,
lateral (select array_agg(cu.customer_code order by cu.customer_code) as c
         from (select cu.customer_code
               from jsonb_array_elements(public.finish_rewash_customer_options_v1(d.day)) o
               join public.customers cu on cu.customer_id=(o->>'customer_id')::uuid
               where cu.legacy_metadata->>'legacy_customer_id' = cu.customer_code
               order by cu.customer_code limit 2) cu) x;

insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by, note)
values ('FINISH_AREA','FINISH_STATUS','Saved','ACTIVE','validation test','test only');

create function pg_temp.hh(p_id text, p_day date, p_time text, p_shift text, p_table text, p_customer text,
                           p_kg text, p_batch text default null, p_units text default null)
returns jsonb language sql as $$
  select jsonb_build_object('source_record_id', p_id, 'wash_item', null,
    'entry', jsonb_strip_nulls(jsonb_build_object('EntryID', p_id, 'CreatedAt', p_day::text||' '||p_time,
      'BusinessDate', p_day::text, 'Shift', p_shift, 'TableID', p_table, 'EntryType', 'HOUSEHOLD',
      'CustomerID', p_customer, 'CustomerName', 'x', 'BatchNo', p_batch, 'QtyKg', p_kg, 'QtyUnits', p_units,
      'TotalKg', p_kg, 'Status', 'Saved', 'Notes', 'household '||p_id)));
$$;

create temporary table t_rec on commit drop as
select 'R1'::text as k, pg_temp.hh('TEST-RW-1', day, '09:10', shift1, table1, cust1, '12.50', 'TESTRW-001') as rec from t_fx
union all select 'R2', pg_temp.hh('TEST-RW-2', day, '10:40', shift1, table1, cust2, '7') from t_fx
union all select 'R3', pg_temp.hh('TEST-RW-3', date '2026-10-25', '11:00', shift1, table1, cust1, '3') from t_fx
union all select 'R9', pg_temp.hh('TEST-RW-9', sunday, '11:00', shift1, table1, cust1, '3') from t_fx
union all select 'R4', pg_temp.hh('TEST-RW-4', day, '12:00', shift2, table2, cust1, '5', null, '2') from t_fx
union all select 'R6', pg_temp.hh('TEST-RW-6', day, '12:30', shift1, table1, cust2, '4', null, '1') from t_fx
union all select 'R7', pg_temp.hh('TEST-RW-7', day, '13:00', shift1, table1, cust2, '6', 'TESTRW-007') from t_fx
union all select 'R8', pg_temp.hh('TEST-RW-8', day, '14:00', shift2, table2, cust2, '9', 'TESTRW-008') from t_fx;

create function pg_temp.rec(p_k text) returns jsonb language sql as $$ select rec from t_rec where k=p_k $$;
create function pg_temp.recs(variadic p_k text[]) returns jsonb language sql as $$
  select jsonb_agg(rec order by array_position(p_k, k)) from t_rec where k = any(p_k)
$$;
create function pg_temp.plan_of(p_result jsonb, p_id text) returns jsonb language sql as $$
  select p from jsonb_array_elements(p_result->'plans') p where p->>'source_record_id'=p_id
$$;
create function pg_temp.has_blocker(p_plan jsonb, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_plan->'blockers','[]'::jsonb)) b where b->>'code'=p_code)
$$;
create function pg_temp.footprint() returns jsonb language sql as $$
  select jsonb_build_object(
    'rewash_entries', (select count(*) from public.finish_rewash_entries),
    'rewash_lines', (select count(*) from public.finish_rewash_lines),
    'finish_entries', (select count(*) from public.finish_production_entries),
    'finish_lines', (select count(*) from public.finish_production_lines),
    'flows', (select count(*) from public.production_flow_items),
    'events', (select count(*) from public.production_flow_events),
    'official_kg', (select coalesce(sum(actual_kg),0) from public.production_official_actuals),
    'audit', (select count(*) from public.audit_log),
    'links', (select count(*) from integration.legacy_sync_record_links),
    'versions', (select count(*) from integration.legacy_sync_record_versions),
    'reviews', (select count(*) from integration.legacy_sync_review_items));
$$;

-- ---------------------------------------------------------------------
-- 3. NORMAL planner: the 2026-10-25 test day skipped, other Sundays kept,
--    HOUSEHOLD routed
-- ---------------------------------------------------------------------
select pg_temp.check(integration.legacy_sync_plan_finish_entry(
         jsonb_set(jsonb_set(pg_temp.rec('R3'),'{entry,EntryType}','"NORMAL"'),'{entry,WashItemID}','"TEST-WI-SUN"'))->>'skip_reason' = 'OWNER_TEST_DAY',
  'a NORMAL row of 2026-10-25 is SKIPPED as the owner test day');
create temporary table t_sun on commit drop as
select integration.legacy_sync_plan_finish_entry(
         jsonb_set(jsonb_set(pg_temp.rec('R9'),'{entry,EntryType}','"NORMAL"'),'{entry,WashItemID}','"TEST-WI-SUN"')) as p;
select pg_temp.check((select p->>'outcome' <> 'SKIPPED'
                        and pg_temp.has_blocker(jsonb_build_object('blockers',p->'warnings'),'SUNDAY_PRODUCTION')
                        and not pg_temp.has_blocker(p,'SUNDAY_PRODUCTION_REVIEW') from t_sun),
  'another Sunday is planned as production with a SUNDAY_PRODUCTION warning');
select pg_temp.check(integration.legacy_sync_plan_finish_entry(pg_temp.rec('R1'))->>'outcome' = 'REWASH_ROUTE',
  'a HOUSEHOLD row is routed to ReWash by the NORMAL planner');

-- ---------------------------------------------------------------------
-- 4. ReWash dry run: outcomes, one READY cell, zero writes
-- ---------------------------------------------------------------------
create temporary table t_before on commit drop as select pg_temp.footprint() as fp;
create temporary table t_dry on commit drop as
select integration.legacy_sync_plan_household_rewash(pg_temp.recs('R1','R2','R3','R4')) as r;

select pg_temp.check((select fp from t_before) = pg_temp.footprint(), 'ReWash dry run wrote nothing');
select pg_temp.check((select (r->>'records')::int=4 and (r->>'ready')::int=2 and (r->>'skipped')::int=1
                        and (r->>'blocked')::int=1 and (r->>'ready_cells')::int=1 from t_dry),
  'dry run: 2 ready, 1 skipped, 1 blocked, 1 ready cell');
select pg_temp.check((select pg_temp.plan_of(r,'TEST-RW-3')->>'skip_reason'='OWNER_TEST_DAY' from t_dry), '2026-10-25 row skipped as the owner test day');
select pg_temp.check((select pg_temp.plan_of(integration.legacy_sync_plan_household_rewash(pg_temp.recs('R9')),'TEST-RW-9')->>'outcome' <> 'SKIPPED'
                        and pg_temp.has_blocker(jsonb_build_object('blockers',
                              pg_temp.plan_of(integration.legacy_sync_plan_household_rewash(pg_temp.recs('R9')),'TEST-RW-9')->'warnings'),
                            'SUNDAY_PRODUCTION')),
  'another Sunday HOUSEHOLD row is planned with a SUNDAY_PRODUCTION warning');
select pg_temp.check((select pg_temp.has_blocker(pg_temp.plan_of(r,'TEST-RW-4'),'REWASH_UNITS_NOT_SUPPORTED') from t_dry),
  'units are refused for ReWash');
select pg_temp.check((select r#>>'{cells,0,shift_code}'=f.shift1 and r#>>'{cells,0,table_code}'=f.table1
                        and (r#>>'{cells,0,production_business_date}')::date=f.day
                        and jsonb_array_length(r#>'{cells,0,lines}')=2
                        and (r#>>'{cells,0,total_kg}')::numeric=19.50
                        and r#>>'{cells,0,lines,0,source_record_id}'='TEST-RW-1'
                        and r#>>'{cells,0,processed_by_name}'='Legacy Finish (Apps Script)'
                      from t_dry, t_fx f),
  'the cell has two KG lines (12.50 + 7) in CreatedAt order');

-- All-or-nothing per cell.
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan_of(integration.legacy_sync_plan_household_rewash(pg_temp.recs('R1','R6')),'TEST-RW-1'),
         'CELL_HAS_BLOCKED_RECORD'), 'one blocked row holds the whole cell');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan_of(integration.legacy_sync_plan_household_rewash(
         jsonb_build_array(pg_temp.rec('R1'), jsonb_set(jsonb_set(pg_temp.rec('R2'),'{entry,BatchNo}','"TESTRW-001"'),'{entry,EntryID}','"TEST-RW-2"'))),
         'TEST-RW-2'), 'BATCH_REFERENCE_DUPLICATE_IN_BATCH'), 'duplicate batch in one call is blocked');

-- ---------------------------------------------------------------------
-- 5. Gates
-- ---------------------------------------------------------------------
create temporary table t_run on commit drop as
select integration.legacy_sync_start_run('FINISH_AREA','COMMIT',(select day from t_fx),(select day from t_fx),'validation test') as run_id;

do $$
begin
  perform integration.legacy_sync_import_household_rewash((select run_id from t_run), pg_temp.recs('R1','R2'));
  raise exception 'FAIL: ReWash import ran while the switch was OFF';
exception when sqlstate '55000' then raise notice 'ok - ReWash import refused while the switch is OFF';
end $$;

update integration.legacy_sync_settings set enabled=true, changed_by='validation test', changed_at=now()
where setting_key='FINISH_REWASH_HISTORICAL_IMPORT';

do $$
declare v_dry uuid := integration.legacy_sync_start_run('FINISH_AREA','DRY_RUN',null,null,'validation test');
begin
  perform integration.legacy_sync_import_household_rewash(v_dry, pg_temp.recs('R1','R2'));
  raise exception 'FAIL: ReWash import ran inside a DRY_RUN run';
exception when sqlstate '55000' then raise notice 'ok - ReWash import refused inside a DRY_RUN run';
end $$;

do $$
begin
  perform integration.legacy_sync_import_household_rewash((select run_id from t_run), pg_temp.recs('R1','R8'));
  raise exception 'FAIL: two cells accepted in one call';
exception when sqlstate '22023' then raise notice 'ok - one Finish cell per call';
end $$;

-- ---------------------------------------------------------------------
-- 6. Import the cell (R1, R2) with a 2026-10-25 test-day row (R3)
-- ---------------------------------------------------------------------
create temporary table t_imp on commit drop as
select integration.legacy_sync_import_household_rewash((select run_id from t_run), pg_temp.recs('R1','R2','R3')) as r;

select pg_temp.check((select r->>'outcome'='IMPORTED' and (r->>'lines_imported')::int=2 from t_imp), 'cell imported with 2 lines');
select pg_temp.check((select e.status='ACTIVE' and e.revision_no=1 and e.entry_group_id=e.finish_rewash_entry_id
                        and e.supersedes_finish_rewash_entry_id is null
                        and e.production_business_date=f.day and e.shift_code_snapshot=f.shift1 and e.table_code_snapshot=f.table1
                        and e.recorded_at=((f.day::text||' 10:40')::timestamp at time zone 'Europe/Dublin')
                        and e.recorded_by_auth_user_id is null and e.recorded_by_staff_id is null
                        and e.processed_by_staff_id is null and e.processed_by_name_snapshot='Legacy Finish (Apps Script)'
                      from public.finish_rewash_entries e, t_imp, t_fx f
                      where e.finish_rewash_entry_id=(t_imp.r->>'finish_rewash_entry_id')::uuid),
  'ReWash entry has the legacy date, shift, table and last CreatedAt');
select pg_temp.check((select string_agg(l.customer_code_snapshot||'='||l.quantity_kg::text||'/'||coalesce(l.batch_reference,'-'), ',' order by l.line_no)
                        = f.cust1||'=12.50/TESTRW-001,'||f.cust2||'=7.00/-'
                      from public.finish_rewash_lines l, t_imp, t_fx f
                      where l.finish_rewash_entry_id=(t_imp.r->>'finish_rewash_entry_id')::uuid
                      group by f.cust1, f.cust2),
  'ReWash lines carry customer, KG and batch');
select pg_temp.check((select count(*)=2 from integration.legacy_sync_record_links
                      where link_role='FINISH_ENTRY_TO_REWASH_LINE' and source_line_key='KG:1'
                        and source_record_id in ('TEST-RW-1','TEST-RW-2')
                        and link_metadata->>'finish_rewash_entry_id'=(select r->>'finish_rewash_entry_id' from t_imp)),
  'one link per legacy row to its ReWash line');
select pg_temp.check((select count(*)=1 from public.audit_log where action='IMPORT_LEGACY_HOUSEHOLD_REWASH'
                        and entity_id=(select r->>'finish_rewash_entry_id' from t_imp) and source_application='LEGACY_SYNC_FINISH'),
  'audit row written');
select pg_temp.check((select count(*)=1 from integration.legacy_sync_review_items
                      where source_record_id='TEST-RW-3' and reason_code='OWNER_TEST_DAY' and status='REJECTED'),
  'test-day row recorded as rejected by owner decision');
select pg_temp.check((select count(*)=3 from integration.legacy_sync_record_versions
                      where source_record_id in ('TEST-RW-1','TEST-RW-2','TEST-RW-3')), 'source versions kept for all three rows');
select pg_temp.check((select (fp->>'finish_entries')=(pg_temp.footprint()->>'finish_entries')
                        and (fp->>'finish_lines')=(pg_temp.footprint()->>'finish_lines')
                        and (fp->>'flows')=(pg_temp.footprint()->>'flows')
                        and (fp->>'events')=(pg_temp.footprint()->>'events')
                        and (fp->>'official_kg')=(pg_temp.footprint()->>'official_kg') from t_before),
  'no Finish production, flow, event or official KG change');

-- ---------------------------------------------------------------------
-- 7. Retry, new row in an imported cell, changed source, run limit
-- ---------------------------------------------------------------------
create temporary table t_mid on commit drop as select pg_temp.footprint() as fp;
create temporary table t_retry on commit drop as
select integration.legacy_sync_import_household_rewash((select run_id from t_run), pg_temp.recs('R1','R2','R3')) as r;
select pg_temp.check((select r->>'outcome'='NOTHING_IMPORTED' and (r->>'already_imported')::int=2 and (r->>'skipped')::int=1 from t_retry),
  'retry returns ALREADY_IMPORTED for the cell rows');
select pg_temp.check((select fp from t_mid) = pg_temp.footprint(), 'retry wrote nothing');

select pg_temp.check(pg_temp.has_blocker(pg_temp.plan_of(integration.legacy_sync_import_household_rewash((select run_id from t_run),
         pg_temp.recs('R7')),'TEST-RW-7'), 'REWASH_CELL_HAS_ACTIVE_ENTRY'),
  'a new row for an imported cell is held, not merged');
select pg_temp.check((select count(*)=1 from integration.legacy_sync_review_items
                      where source_record_id='TEST-RW-7' and reason_code='REWASH_CELL_HAS_ACTIVE_ENTRY' and status='OPEN'),
  'review item opened for the held row');
select pg_temp.check((select count(*)=1 from public.finish_rewash_entries e, t_fx f
                      where e.status='ACTIVE' and e.production_business_date=f.day
                        and e.shift_code_snapshot=f.shift1 and e.table_code_snapshot=f.table1),
  'the cell still has exactly one ACTIVE ReWash entry');

select pg_temp.check(pg_temp.has_blocker(pg_temp.plan_of(integration.legacy_sync_import_household_rewash((select run_id from t_run),
         jsonb_build_array(jsonb_set(pg_temp.rec('R1'),'{entry,QtyKg}','"13"'))),'TEST-RW-1'), 'SOURCE_CHANGED_AFTER_IMPORT'),
  'changed source is blocked as SOURCE_CHANGED_AFTER_IMPORT');

update integration.legacy_sync_settings set max_entries_per_run=1, changed_by='validation test'
where setting_key='FINISH_REWASH_HISTORICAL_IMPORT';
select pg_temp.check(integration.legacy_sync_import_household_rewash((select run_id from t_run), pg_temp.recs('R8'))->>'outcome'
         = 'RUN_LIMIT_REACHED', 'run limit counts ReWash cells');

-- ---------------------------------------------------------------------
-- 8. Immutability
-- ---------------------------------------------------------------------
do $$
begin
  update integration.legacy_sync_record_links set source_fingerprint='tampered' where source_record_id='TEST-RW-1';
  raise exception 'FAIL: a ReWash link was updated';
exception when sqlstate '55000' then raise notice 'ok - ReWash links are insert-only';
end $$;

do $$
begin
  update integration.legacy_sync_review_items set decision='{}' where source_record_id='TEST-RW-3';
  raise exception 'FAIL: the test-day decision was changed';
exception when sqlstate '55000' then raise notice 'ok - the test-day decision cannot change';
end $$;

select 'PASS: 202610270002_legacy_sync_household_rewash_import_validation' as result;

rollback;
