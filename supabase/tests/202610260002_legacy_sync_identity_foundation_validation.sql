-- ElisCaretex V2 - Validation - 202610260002_legacy_sync_identity_foundation
-- Runs inside one transaction and ends with ROLLBACK: nothing is kept.
-- Plain SQL assertions (pgTAP is not installed on the remote project).

begin;

create function pg_temp.check(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'ok - %', p_label;
end;
$$;

select pg_temp.check(to_regclass('integration.legacy_sync_runs') is not null
  and to_regclass('integration.legacy_sync_record_versions') is not null
  and to_regclass('integration.legacy_sync_record_links') is not null
  and to_regclass('integration.legacy_sync_review_items') is not null, 'four foundation tables exist');

select pg_temp.check((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
                      where n.nspname='integration' and c.relname like 'legacy_sync_%' and c.relkind='r'),
  'RLS is enabled on every legacy_sync table');

select pg_temp.check(not has_table_privilege('authenticated','integration.legacy_sync_record_links','select')
  and not has_table_privilege('anon','integration.legacy_sync_runs','insert'), 'client roles have no table access');

insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, source_line_key,
  link_role, target_table, target_id, source_fingerprint)
values ('TEST','FinishEntries','E1','KG:1','FINISH_ENTRY_TO_LINE','public.finish_production_lines',gen_random_uuid(),'f'),
       ('TEST','FinishEntries','E1','UNIT:2','FINISH_ENTRY_TO_LINE','public.finish_production_lines',gen_random_uuid(),'f');
select pg_temp.check((select count(*)=2 from integration.legacy_sync_record_links where source_system='TEST'),
  'one legacy entry links to a KG and a UNIT line');

do $$
begin
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint)
  values ('TEST','FinishEntries','E1','FINISH_ENTRY_TO_LINE','public.finish_production_lines',gen_random_uuid(),'f');
  raise exception 'FAIL: line link without source_line_key accepted';
exception when check_violation then raise notice 'ok - line link needs source_line_key';
end $$;

do $$
begin
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, source_line_key,
    link_role, target_table, target_id, source_fingerprint)
  values ('TEST','FinishEntries','E1','KG:1','FINISH_ENTRY_TO_LINE','public.finish_production_lines',gen_random_uuid(),'f');
  raise exception 'FAIL: duplicate line link accepted';
exception when unique_violation then raise notice 'ok - duplicate line link refused';
end $$;

do $$
begin
  update integration.legacy_sync_record_links set source_fingerprint='x' where source_system='TEST';
  raise exception 'FAIL: link updated';
exception when sqlstate '55000' then raise notice 'ok - links cannot be updated';
end $$;

do $$
begin
  delete from integration.legacy_sync_record_links where source_system='TEST';
  raise exception 'FAIL: link deleted';
exception when sqlstate '55000' then raise notice 'ok - links cannot be deleted';
end $$;

do $$
begin
  insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id, reason_code, status)
  values ('TEST','FinishEntries','E2','X','APPROVED');
  raise exception 'FAIL: decided review item without decision fields accepted';
exception when check_violation then raise notice 'ok - a decision needs author, date and decision';
end $$;

insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id, reason_code)
values ('TEST','FinishEntries','E2','X');
update integration.legacy_sync_review_items
set status='APPROVED', decided_at=now(), decided_by='validation test', decision='{"ok":true}'
where source_system='TEST';
select pg_temp.check((select status='APPROVED' from integration.legacy_sync_review_items where source_system='TEST'),
  'an OPEN review item can be decided once');

do $$
begin
  update integration.legacy_sync_review_items set decision='{}' where source_system='TEST';
  raise exception 'FAIL: decided review item changed';
exception when sqlstate '55000' then raise notice 'ok - a decided review item cannot change';
end $$;

select 'PASS: 202610260002_legacy_sync_identity_foundation_validation' as result;

rollback;
