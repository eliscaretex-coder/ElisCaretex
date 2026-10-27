-- Legacy Sync: pending items on the Apps Script page (owner request 2026-10-27).
--
-- Records the sync could not import wait in integration.legacy_sync_review_items. Until now
-- the page only counted them. The owner wants to see each one and record a choice:
--
--   * FIX_IN_SOURCE  "I will correct it in the legacy sheet" (status APPROVED);
--   * NOT_IMPORTED   "Do not import this record" (status REJECTED).
--
-- Either choice is kept with who decided, when, an optional note and the fingerprint of the
-- record version it applies to. The sync does not raise the same item again for that version;
-- when the legacy row changes, the sync reads it again (imports it, or raises a new item).
-- Items that only wait for another part (WASH_NOT_IN_V2, MOP_NOT_IN_V2, ...) need no choice:
-- once the record is imported they are closed as SUPERSEDED when the list is read.
-- Review items stay append-only for decided rows (legacy_sync_review_guard).

begin;

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
      -- The owner already decided this version of the record (fix it in the sheet, or do
      -- not import it): no new review item until the legacy row changes.
      continue when exists (
        select 1 from integration.legacy_sync_review_items ri
        where ri.source_system=p_source_system and ri.source_table=p_source_table
          and ri.source_record_id=v_id and ri.reason_code=v_blocker->>'code'
          and ri.status in ('APPROVED','REJECTED')
          and ri.decision->>'action' in ('FIX_IN_SOURCE','NOT_IMPORTED')
          and ri.raw->>'fingerprint' is not distinct from p_plan->>'fingerprint');
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

create or replace function integration.legacy_sync_review_waiting_codes()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array['WASH_NOT_IN_V2','MOP_NOT_IN_V2','FINISH_ENTRY_NOT_IN_V2','TROLLEY_NOT_IN_V2']::text[];
$$;

-- List for the Apps Script page. Closes open items whose record has since been imported.
create or replace function integration.legacy_sync_review_list()
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='Legacy sync reviews are not available to accounts.';
  end if;

  update integration.legacy_sync_review_items ri
  set status='SUPERSEDED', decided_at=now(), decided_by='Legacy sync',
      decision=jsonb_build_object('action','IMPORTED_LATER')
  where ri.status='OPEN'
    and exists (select 1 from integration.legacy_sync_record_links l
                where l.source_system=ri.source_system and l.source_table=ri.source_table
                  and l.source_record_id=ri.source_record_id and l.created_at > ri.created_at);

  return jsonb_build_object(
    'open', coalesce((
      select jsonb_agg(jsonb_build_object(
          'review_id', ri.review_id, 'source_system', ri.source_system, 'source_table', ri.source_table,
          'source_record_id', ri.source_record_id, 'reason_code', ri.reason_code,
          'detail', ri.raw->>'detail', 'row', ri.raw->'record'->'row', 'created_at', ri.created_at,
          'waiting', ri.reason_code = any(integration.legacy_sync_review_waiting_codes()))
        order by (ri.reason_code = any(integration.legacy_sync_review_waiting_codes())), ri.created_at)
      from integration.legacy_sync_review_items ri where ri.status='OPEN'), '[]'::jsonb),
    'decided', coalesce((
      select jsonb_agg(x order by x->>'decided_at' desc) from (
        select jsonb_build_object(
            'review_id', ri.review_id, 'source_table', ri.source_table, 'source_record_id', ri.source_record_id,
            'reason_code', ri.reason_code, 'detail', ri.raw->>'detail', 'status', ri.status,
            'action', ri.decision->>'action', 'note', ri.decision->>'note',
            'decided_by', ri.decided_by, 'decided_at', ri.decided_at) x
        from integration.legacy_sync_review_items ri
        where ri.status in ('APPROVED','REJECTED') and ri.reason_code <> 'OWNER_TEST_DAY'
        order by ri.decided_at desc limit 30) d), '[]'::jsonb));
end;
$$;

-- One owner choice for one open item.
create or replace function integration.legacy_sync_review_decide(
  p_review_id uuid, p_action text, p_decided_by text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_action text := upper(btrim(coalesce(p_action,'')));
  v_who text := nullif(btrim(coalesce(p_decided_by,'')),'');
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_item integration.legacy_sync_review_items%rowtype;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='Legacy sync reviews are not available to accounts.';
  end if;
  if v_action not in ('FIX_IN_SOURCE','NOT_IMPORTED') then
    raise exception using errcode='22023', message='Action must be FIX_IN_SOURCE or NOT_IMPORTED.';
  end if;
  if v_who is null or length(v_who) > 200 then
    raise exception using errcode='22023', message='decided_by is required.';
  end if;
  if length(v_note) > 500 then
    raise exception using errcode='22023', message='The note is limited to 500 characters.';
  end if;

  select * into v_item from integration.legacy_sync_review_items where review_id=p_review_id for update;
  if not found then
    raise exception using errcode='P0002', message='Review item not found.';
  end if;
  if v_item.status <> 'OPEN' then
    raise exception using errcode='55000', message='This item was already decided.';
  end if;

  update integration.legacy_sync_review_items
  set status = case when v_action='NOT_IMPORTED' then 'REJECTED' else 'APPROVED' end,
      decision = jsonb_build_object('action', v_action, 'note', v_note, 'fingerprint', v_item.raw->>'fingerprint'),
      decided_by = v_who, decided_at = now()
  where review_id = p_review_id;

  return jsonb_build_object('review_id', p_review_id, 'action', v_action);
end;
$$;

revoke all on function integration.legacy_sync_hold_for_review(text,text,jsonb,jsonb,uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_waiting_codes() from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_list() from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_decide(uuid,text,text,text) from public, anon, authenticated;
grant execute on function integration.legacy_sync_review_list() to service_role;
grant execute on function integration.legacy_sync_review_decide(uuid,text,text,text) to service_role;

comment on function integration.legacy_sync_review_list() is
  'Apps Script page: open legacy sync review items and the last 30 owner decisions. Closes items whose record was imported since. service_role only.';
comment on function integration.legacy_sync_review_decide(uuid,text,text,text) is
  'Apps Script page: records the owner choice (FIX_IN_SOURCE or NOT_IMPORTED) for one open review item. service_role only.';

commit;
