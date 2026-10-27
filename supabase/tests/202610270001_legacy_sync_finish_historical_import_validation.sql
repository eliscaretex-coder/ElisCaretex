-- ElisCaretex V2 - Validation - 202610270001_legacy_sync_finish_historical_import
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
-- 1. Privileges and switch
-- ---------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated','integration.legacy_sync_import_finish_entry(uuid,jsonb)','execute'),
  'authenticated cannot call the importer');
select pg_temp.check(not has_function_privilege('anon','integration.legacy_sync_finish_dry_run(jsonb)','execute'),
  'anon cannot call the dry run');
select pg_temp.check(has_function_privilege('service_role','integration.legacy_sync_import_finish_entry(uuid,jsonb)','execute'),
  'service_role can call the importer');
select pg_temp.check(not has_table_privilege('authenticated','integration.legacy_sync_settings','select'),
  'authenticated cannot read settings');
select pg_temp.check(not has_table_privilege('authenticated','integration.legacy_sync_finish_insert_permits','insert'),
  'authenticated cannot write insert permits');
select pg_temp.check((select not enabled and max_entries_per_run=3 from integration.legacy_sync_settings
                      where setting_key='FINISH_HISTORICAL_IMPORT'), 'import switch is seeded OFF with pilot limit 3');

-- ---------------------------------------------------------------------
-- 2. Fixture: a customer with a published CLOTHES schedule and no flow
--    on a recent Tuesday-Saturday; business date is the day before
--    (advance production).
-- ---------------------------------------------------------------------
create function pg_temp.published(p_customer uuid, p_date date) returns boolean language plpgsql as $$
begin
  perform 1 from public.sorting_schedule_product_snapshot(p_customer,'CLOTHES',p_date);
  return true;
exception when others then
  return false;
end;
$$;

create temporary table t_fixture on commit drop as
select c.customer_id, c.customer_code, d.scheduled, (d.scheduled - 1) as business
from public.customers c
cross join lateral (
  select gs::date as scheduled
  from generate_series(current_date - 21, current_date - 2, interval '1 day') gs
  where extract(isodow from gs) between 2 and 6
) d
where c.deleted_at is null and c.active
  and c.legacy_metadata->>'legacy_customer_id' = c.customer_code
  and not exists (select 1 from public.production_flow_items f
                  where f.customer_id=c.customer_id and f.product_code='CLOTHES' and f.scheduled_for_date=d.scheduled)
  and pg_temp.published(c.customer_id, d.scheduled)
order by d.scheduled desc, c.customer_code
limit 1;

select pg_temp.check((select count(*)=1 from t_fixture), 'fixture customer and scheduled date found');

insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by, note)
values ('FINISH_AREA','FINISH_STATUS','Saved','ACTIVE','validation test','test only'),
       ('FINISH_AREA','FINISH_TABLE','Table 2','FINISH_TABLE_2','validation test','test only');

create temporary table t_rec on commit drop as
select 'A'::text as k, jsonb_build_object(
  'source_record_id','TEST-LS-A',
  'entry', jsonb_build_object('EntryID','TEST-LS-A','CreatedAt',(f.business::text||' 10:15:00'),
     'BusinessDate',f.business::text,'Shift','MORNING','TableID','FINISH_TABLE_1','EntryType','NORMAL',
     'WashItemID','TEST-WI-1','CustomerID',f.customer_code,'CustomerName','x','Trolleys','T-001, T-002',
     'BatchNo','TESTLS-A-001','QtyKg','45.50','QtyUnits','12','TotalKg','45.5','Status','Saved','Notes','pilot'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-1','CustomerID',f.customer_code,
     'ScheduledDate',f.scheduled::text,'Type','CLOTHES')) as rec
from t_fixture f
union all
select 'B', jsonb_build_object('source_record_id','TEST-LS-B',
  'entry', jsonb_build_object('EntryID','TEST-LS-B','CreatedAt',f.business::text||' 11:00','BusinessDate',f.business::text,
     'Shift','MORNING','TableID','FINISH_TABLE_1','EntryType','HOUSEHOLD','CustomerID',f.customer_code,
     'BatchNo','TESTLS-B-001','QtyKg','10','Status','Saved'),
  'wash_item', null) from t_fixture f
union all
select 'C', jsonb_build_object('source_record_id','TEST-LS-C',
  'entry', jsonb_build_object('EntryID','TEST-LS-C','CreatedAt',f.business::text||' 11:00','BusinessDate',f.business::text,
     'Shift','MORNING','TableID','FINISH_TABLE_3','EntryType','NORMAL','WashItemID','TEST-WI-9','CustomerID','NO-SUCH-CUSTOMER',
     'BatchNo','TESTLS-C-001','QtyKg','10','Status','Saved'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-9','CustomerID','NO-SUCH-CUSTOMER','ScheduledDate',f.scheduled::text,'Type','CLOTHES'))
from t_fixture f
union all
-- D: same flow, date, shift and table as A -> needs an owner decision
select 'D', jsonb_build_object('source_record_id','TEST-LS-D',
  'entry', jsonb_build_object('EntryID','TEST-LS-D','CreatedAt',f.business::text||' 12:00','BusinessDate',f.business::text,
     'Shift','MORNING','TableID','FINISH_TABLE_1','EntryType','NORMAL','WashItemID','TEST-WI-2','CustomerID',f.customer_code,
     'BatchNo','TESTLS-D-001','QtyKg','20','Status','Saved'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-2','CustomerID',f.customer_code,'ScheduledDate',f.scheduled::text,'Type','CLOTHES'))
from t_fixture f
union all
-- E: TotalKg disagrees with QtyKg; comma decimal in units
select 'E', jsonb_build_object('source_record_id','TEST-LS-E',
  'entry', jsonb_build_object('EntryID','TEST-LS-E','CreatedAt',f.business::text||' 12:00','BusinessDate',f.business::text,
     'Shift','EVENING','TableID','FINISH_TABLE_3','EntryType','NORMAL','WashItemID','TEST-WI-3','CustomerID',f.customer_code,
     'BatchNo','TESTLS-E-001','QtyKg','20','QtyUnits','1,5','TotalKg','25','Status','Saved'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-3','CustomerID',f.customer_code,'ScheduledDate',f.scheduled::text,'Type','CLOTHES'))
from t_fixture f
union all
-- G: second WashItem of the same flow, mapped table "Table 2", afternoon shift
select 'G', jsonb_build_object('source_record_id','TEST-LS-G',
  'entry', jsonb_build_object('EntryID','TEST-LS-G','CreatedAt',f.scheduled::text||'T15:30:00+00:00','BusinessDate',f.scheduled::text,
     'Shift','EVENING','TableID','table  2','EntryType','NORMAL','WashItemID','TEST-WI-4','CustomerID',f.customer_code,
     'BatchNo','TESTLS-G-001','QtyKg','30.25','Status','Saved'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-4','CustomerID',f.customer_code,'ScheduledDate',f.scheduled::text,'Type','CLOTHES'))
from t_fixture f
union all
-- H: unmapped legacy WashItem type
select 'H', jsonb_build_object('source_record_id','TEST-LS-H',
  'entry', jsonb_build_object('EntryID','TEST-LS-H','CreatedAt',f.business::text||' 12:00','BusinessDate',f.business::text,
     'Shift','EVENING','TableID','FINISH_TABLE_1','EntryType','NORMAL','WashItemID','TEST-WI-5','CustomerID',f.customer_code,
     'BatchNo','TESTLS-H-001','QtyKg','5','Status','Saved'),
  'wash_item', jsonb_build_object('WashItemID','TEST-WI-5','CustomerID',f.customer_code,'ScheduledDate',f.scheduled::text,'Type','Duvets'))
from t_fixture f;

create function pg_temp.rec(p_k text) returns jsonb language sql as $$ select rec from t_rec where k=p_k $$;

create function pg_temp.footprint() returns jsonb language sql as $$
  select jsonb_build_object(
    'entries', (select count(*) from public.finish_production_entries),
    'lines', (select count(*) from public.finish_production_lines),
    'flows', (select count(*) from public.production_flow_items),
    'events', (select count(*) from public.production_flow_events),
    'audit', (select count(*) from public.audit_log),
    'links', (select count(*) from integration.legacy_sync_record_links),
    'versions', (select count(*) from integration.legacy_sync_record_versions),
    'reviews', (select count(*) from integration.legacy_sync_review_items),
    'runs', (select count(*) from integration.legacy_sync_runs),
    'stays', (select count(*) from public.trolley_customer_stays),
    'trolley_events', (select count(*) from public.trolley_events),
    'finish_trolleys', (select count(*) from public.finish_production_trolleys),
    'trolley_status', (select md5(coalesce(string_agg(trolley_id::text||status, ',' order by trolley_id),'')) from public.trolleys),
    'intakes', (select count(*) from public.sorting_trolley_intakes),
    'wash_runs', (select count(*) from public.sorting_wash_runs));
$$;

-- ---------------------------------------------------------------------
-- 3. Dry run: correct outcomes and zero writes
-- ---------------------------------------------------------------------
create temporary table t_before on commit drop as select pg_temp.footprint() as fp;

create temporary table t_dry on commit drop as
select integration.legacy_sync_finish_dry_run((select jsonb_agg(rec order by k) from t_rec)) as r;

create function pg_temp.plan(p_id text) returns jsonb language sql as $$
  select p from t_dry, jsonb_array_elements(r->'plans') p where p->>'source_record_id'=p_id
$$;
create function pg_temp.has_blocker(p_plan jsonb, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_plan->'blockers','[]'::jsonb)) b where b->>'code'=p_code)
$$;

select pg_temp.check((select fp from t_before) = pg_temp.footprint(), 'dry run wrote nothing');
select pg_temp.check((select (r->>'writes_performed')::int = 0 and (r->>'records')::int = 7 from t_dry), 'dry run reports 7 records, 0 writes');
select pg_temp.check((select (r->>'rewash_route')::int = 1 and (r->>'skipped')::int = 0 from t_dry), 'dry run counts 1 ReWash route, 0 skipped');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-A'),'CELL_SHARED_IN_BATCH'), 'A and D share a Finish cell in the batch');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-D'),'CELL_SHARED_IN_BATCH'), 'D is held with A');
-- Since 202610270002 HOUSEHOLD is ReWash (owner decision 2026-10-27): routed, not blocked here.
select pg_temp.check(pg_temp.plan('TEST-LS-B')->>'outcome' = 'REWASH_ROUTE', 'HOUSEHOLD is routed to the ReWash importer');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-C'),'CUSTOMER_NOT_FOUND'), 'unknown customer is blocked');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-E'),'TOTAL_KG_MISMATCH'), 'TotalKg mismatch is blocked');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-E'),'INVALID_QUANTITY'), 'comma decimal is refused');
select pg_temp.check(pg_temp.has_blocker(pg_temp.plan('TEST-LS-H'),'WASH_ITEM_TYPE_UNMAPPED'), 'unmapped WashItem type is blocked');
select pg_temp.check(pg_temp.plan('TEST-LS-G')->>'outcome' = 'READY', 'G is READY (mapped table value, offset timestamp)');
select pg_temp.check(pg_temp.plan('TEST-LS-G')#>>'{resolved,table_code}' = 'FINISH_TABLE_2', 'owner map resolves "table  2"');

-- Single-record plan of A (no batch neighbours) is READY with two lines and advance production.
create temporary table t_plan_a on commit drop as select integration.legacy_sync_plan_finish_entry(pg_temp.rec('A')) as p;
select pg_temp.check((select p->>'outcome'='READY' from t_plan_a), 'A alone is READY');
select pg_temp.check((select jsonb_array_length(p->'lines')=2 and p#>>'{lines,0,source_line_key}'='KG:1'
                      and p#>>'{lines,1,source_line_key}'='UNIT:2' from t_plan_a), 'A has KG:1 and UNIT:2 lines');
select pg_temp.check((select p#>>'{resolved,flow_action}'='CREATE' from t_plan_a), 'A plans a new flow');
select pg_temp.check((select (p#>>'{resolved,delivery_date}')::date = public.next_distribution_business_date(f.scheduled)
                      from t_plan_a, t_fixture f), 'delivery date derives from the scheduled date');
select pg_temp.check((select pg_temp.has_blocker(jsonb_build_object('blockers',p->'warnings'),'ADVANCE_PRODUCTION') from t_plan_a),
  'advance production is a warning, not a blocker');

-- ---------------------------------------------------------------------
-- 4. Gates: switch off, then dry-run run
-- ---------------------------------------------------------------------
create temporary table t_run on commit drop as
select integration.legacy_sync_start_run('FINISH_AREA','COMMIT',(select business from t_fixture),(select scheduled from t_fixture),'validation test') as run_id;

do $$
begin
  perform integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('A'));
  raise exception 'FAIL: import ran while the switch was OFF';
exception when sqlstate '55000' then raise notice 'ok - import refused while the switch is OFF';
end $$;

update integration.legacy_sync_settings set enabled=true, changed_by='validation test', changed_at=now()
where setting_key='FINISH_HISTORICAL_IMPORT';

do $$
declare v_dry uuid := integration.legacy_sync_start_run('FINISH_AREA','DRY_RUN',null,null,'validation test');
begin
  perform integration.legacy_sync_import_finish_entry(v_dry, pg_temp.rec('A'));
  raise exception 'FAIL: import ran inside a DRY_RUN run';
exception when sqlstate '55000' then raise notice 'ok - import refused inside a DRY_RUN run';
end $$;

-- ---------------------------------------------------------------------
-- 5. Import A, then G (same flow), then retries and changes
-- ---------------------------------------------------------------------
create temporary table t_a on commit drop as
select integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('A')) as r;

select pg_temp.check((select r->>'outcome'='IMPORTED' from t_a), 'A imported');
select pg_temp.check((select e.status='ACTIVE' and e.source_application='LEGACY_SYNC_FINISH' and e.revision_no=1
                        and e.production_business_date=f.business and e.delivery_date=public.next_distribution_business_date(f.scheduled)
                        and e.shift_code_snapshot='MORNING' and e.table_code_snapshot='FINISH_TABLE_1'
                        and e.recorded_at = ((f.business::text||' 10:15:00')::timestamp at time zone 'Europe/Dublin')
                        and e.recorded_by_auth_user_id is null and e.trolley_scan_status='UNSPECIFIED'
                      from public.finish_production_entries e, t_a, t_fixture f
                      where e.finish_production_entry_id=(t_a.r->>'finish_production_entry_id')::uuid),
  'A entry has the legacy dates, shift, table and provenance');
select pg_temp.check((select string_agg(l.unit_code||'='||l.quantity::text, ',' order by l.line_no) = 'KG=45.50,UNIT=12.00'
                      from public.finish_production_lines l, t_a
                      where l.finish_production_entry_id=(t_a.r->>'finish_production_entry_id')::uuid),
  'A lines are KG 45.50 and UNIT 12');
select pg_temp.check((select f.flow_origin='SCHEDULED' and f.scheduled_for_date=x.scheduled and f.opened_business_date=x.business
                        and f.current_stage_code='PRODUCTION' and f.event_count=1
                      from public.production_flow_items f, t_a, t_fixture x
                      where f.production_flow_item_id=(t_a.r->>'production_flow_item_id')::uuid),
  'flow created by key, opened on the legacy business date, stage PRODUCTION');
select pg_temp.check((select count(*)=1 from public.production_flow_events ev, t_a
                      where ev.production_flow_item_id=(t_a.r->>'production_flow_item_id')::uuid
                        and ev.event_type='FINISH_PRODUCTION_RECORDED' and ev.source_application='LEGACY_SYNC_FINISH'),
  'one FINISH_PRODUCTION_RECORDED event with legacy provenance');
select pg_temp.check((select count(*)=0 from public.production_flow_events ev, t_a
                      where ev.production_flow_item_id=(t_a.r->>'production_flow_item_id')::uuid and ev.event_type like 'WASH%'),
  'no wash event fabricated');
select pg_temp.check((select count(*)=4 from integration.legacy_sync_record_links where source_record_id in ('TEST-LS-A','TEST-WI-1')),
  'links: entry, 2 lines, WashItem');
select pg_temp.check((select coalesce(sum(actual_kg),0)=45.50 from public.production_official_actuals
                      where source_record_id=(select (r->>'finish_production_entry_id')::uuid from t_a)),
  'official KG counts 45.50 (UNIT excluded)');
select pg_temp.check((select count(*)=1 from public.audit_log where action='IMPORT_LEGACY_FINISH_ENTRY'
                        and entity_id=(select r->>'finish_production_entry_id' from t_a)), 'audit row written');
select pg_temp.check((select count(*)=0 from integration.legacy_sync_finish_insert_permits), 'insert permit consumed');

create temporary table t_g on commit drop as
select integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('G')) as r;
select pg_temp.check((select r->>'outcome'='IMPORTED' from t_g), 'G imported');
select pg_temp.check((select t_g.r->>'production_flow_item_id' = t_a.r->>'production_flow_item_id' from t_g, t_a),
  'G reuses the same flow (one flow per customer + product + scheduled date)');
select pg_temp.check((select count(*)=1 from public.production_flow_items f, t_fixture x
                      where f.customer_id=x.customer_id and f.product_code='CLOTHES' and f.scheduled_for_date=x.scheduled),
  'exactly one flow for the key');
select pg_temp.check((select count(*)=2 from integration.legacy_sync_record_links
                      where link_role='WASH_ITEM_TO_FLOW' and target_id=(select (r->>'production_flow_item_id')::uuid from t_a)),
  'two WashItems link to that one flow');

-- Retry A: nothing new.
create temporary table t_mid on commit drop as select pg_temp.footprint() as fp;
select pg_temp.check(integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('A'))->>'outcome' = 'ALREADY_IMPORTED',
  'retry of A returns ALREADY_IMPORTED');
select pg_temp.check((select fp from t_mid) = pg_temp.footprint(), 'retry wrote nothing');

-- A changed in the legacy sheet: held for review, nothing overwritten.
select pg_temp.check(pg_temp.has_blocker(integration.legacy_sync_import_finish_entry((select run_id from t_run),
         jsonb_set(pg_temp.rec('A'), '{entry,QtyKg}', '"50"')), 'SOURCE_CHANGED_AFTER_IMPORT'),
  'changed source is blocked as SOURCE_CHANGED_AFTER_IMPORT');
select pg_temp.check((select sum(quantity)=57.50 from public.finish_production_lines l, t_a
                      where l.finish_production_entry_id=(t_a.r->>'finish_production_entry_id')::uuid),
  'imported quantities unchanged');
select pg_temp.check((select count(*)=1 from integration.legacy_sync_review_items
                      where source_record_id='TEST-LS-A' and reason_code='SOURCE_CHANGED_AFTER_IMPORT' and status='OPEN'),
  'review item opened for the change');

-- D now hits the ACTIVE cell written by A.
select pg_temp.check(pg_temp.has_blocker(integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('D')),
         'CELL_HAS_ACTIVE_ENTRY'), 'D is blocked by the ACTIVE cell');

-- Blocked twice: one open review item per reason.
select pg_temp.check(integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('C'))->>'outcome' = 'BLOCKED',
  'unknown customer import is BLOCKED');
select pg_temp.check(integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('C'))->>'outcome' = 'BLOCKED',
  'unknown customer retry is BLOCKED again');
select pg_temp.check((select count(*)=1 from integration.legacy_sync_review_items
                      where source_record_id='TEST-LS-C' and reason_code='CUSTOMER_NOT_FOUND'),
  'repeated blocked record keeps one open review item per reason');

-- HOUSEHOLD sent to the NORMAL importer: routed, no Finish row, no review item.
select pg_temp.check(integration.legacy_sync_import_finish_entry((select run_id from t_run), pg_temp.rec('B'))->>'outcome' = 'REWASH_ROUTE',
  'NORMAL importer does not import HOUSEHOLD');
select pg_temp.check((select count(*)=0 from integration.legacy_sync_review_items where source_record_id='TEST-LS-B'),
  'HOUSEHOLD routed without a review item');

-- Run limit.
update integration.legacy_sync_settings set max_entries_per_run=2, changed_by='validation test' where setting_key='FINISH_HISTORICAL_IMPORT';
select pg_temp.check(integration.legacy_sync_import_finish_entry((select run_id from t_run),
         jsonb_set(jsonb_set(jsonb_set(pg_temp.rec('G'),'{source_record_id}','"TEST-LS-I"'),'{entry,EntryID}','"TEST-LS-I"'),
                   '{entry,BatchNo}','"TESTLS-I-001"'))->>'outcome' = 'RUN_LIMIT_REACHED',
  'run limit stops the third entry');

-- Nothing touched trolleys, custody or Sorting.
select pg_temp.check((select (fp->>'stays') = (pg_temp.footprint()->>'stays')
                        and (fp->>'trolley_events') = (pg_temp.footprint()->>'trolley_events')
                        and (fp->>'finish_trolleys') = (pg_temp.footprint()->>'finish_trolleys')
                        and (fp->>'trolley_status') = (pg_temp.footprint()->>'trolley_status')
                        and (fp->>'intakes') = (pg_temp.footprint()->>'intakes')
                        and (fp->>'wash_runs') = (pg_temp.footprint()->>'wash_runs') from t_before),
  'no trolley, custody or Sorting rows changed');

-- ---------------------------------------------------------------------
-- 6. Trigger and immutability
-- ---------------------------------------------------------------------
do $$
declare v_flow uuid := (select (r->>'production_flow_item_id')::uuid from t_a);
begin
  insert into public.finish_production_entries(entry_group_id, revision_no, status, production_flow_item_id, customer_id,
    production_business_date, delivery_date, edit_cutoff_at, shift_id, shift_code_snapshot, station_id,
    table_code_snapshot, table_name_snapshot, source_application)
  select gen_random_uuid(), 1, 'ACTIVE', e.production_flow_item_id, e.customer_id, e.production_business_date,
    e.delivery_date, e.edit_cutoff_at, e.shift_id, 'EVENING', e.station_id, 'FINISH_TABLE_3', e.table_name_snapshot,
    'LEGACY_SYNC_FINISH'
  from public.finish_production_entries e where e.production_flow_item_id=v_flow limit 1;
  raise exception 'FAIL: a LEGACY_SYNC_FINISH row was inserted without a permit';
exception when sqlstate '42501' then raise notice 'ok - LEGACY_SYNC_FINISH label alone is refused by the trigger';
end $$;

-- Live rule unchanged: a direct FINISH_V2 insert outside the RPCs is still refused.
do $$
declare v_flow uuid := (select (r->>'production_flow_item_id')::uuid from t_a);
begin
  insert into public.finish_production_entries(entry_group_id, revision_no, status, production_flow_item_id, customer_id,
    production_business_date, delivery_date, edit_cutoff_at, shift_id, shift_code_snapshot, station_id,
    table_code_snapshot, table_name_snapshot, source_application)
  select gen_random_uuid(), 1, 'ACTIVE', e.production_flow_item_id, e.customer_id, e.production_business_date,
    e.delivery_date, e.edit_cutoff_at, e.shift_id, 'EVENING', e.station_id, 'FINISH_TABLE_3', e.table_name_snapshot,
    'FINISH_V2'
  from public.finish_production_entries e where e.production_flow_item_id=v_flow limit 1;
  raise exception 'FAIL: a direct FINISH_V2 insert passed the live shift rule';
exception
  when sqlstate 'P0001' then raise;
  when others then
    if sqlerrm like '%legacy sync importer%' then raise; end if;
    raise notice 'ok - direct FINISH_V2 insert still refused by the live rule (%)', sqlerrm;
end $$;

do $$
begin
  update integration.legacy_sync_record_links set source_fingerprint='tampered' where source_record_id='TEST-LS-A';
  raise exception 'FAIL: a link was updated';
exception when sqlstate '55000' then raise notice 'ok - links are insert-only';
end $$;

do $$
begin
  update integration.legacy_sync_value_maps set canonical_value='FINISH_TABLE_3' where raw_value='Table 2';
  raise exception 'FAIL: a value map was edited';
exception when sqlstate '55000' then raise notice 'ok - value maps cannot be edited';
end $$;

select 'PASS: 202610270001_legacy_sync_finish_historical_import_validation' as result;

rollback;
