-- Validation for 202610270014_legacy_sync_pending_review.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change, so nothing is kept.
do $$
declare
  v_plan jsonb := jsonb_build_object('outcome','BLOCKED','source_record_id','VALIDATION-0014-A','fingerprint','sha256:v1',
                    'blockers', jsonb_build_array(jsonb_build_object('code','INVALID_QUANTITY','detail','QtyKg=0.012')));
  v_id uuid;
  v_n int;
  v_list jsonb;
begin
  -- 1. A blocked record raises one open item, once.
  perform integration.legacy_sync_hold_for_review('FINISH_AREA','FinishEntries', v_plan, '{"row":{}}'::jsonb, null);
  perform integration.legacy_sync_hold_for_review('FINISH_AREA','FinishEntries', v_plan, '{"row":{}}'::jsonb, null);
  select count(*), min(review_id::text)::uuid into v_n, v_id from integration.legacy_sync_review_items
  where source_record_id='VALIDATION-0014-A' and status='OPEN';
  if v_n <> 1 then raise exception 'FAILED 1: % open items', v_n; end if;

  -- 2. The list shows it, not waiting.
  v_list := integration.legacy_sync_review_list();
  if not exists (select 1 from jsonb_array_elements(v_list->'open') o
                 where (o->>'review_id')::uuid = v_id and not (o->>'waiting')::boolean) then
    raise exception 'FAILED 2: the open item is not listed';
  end if;

  -- 3. Bad decisions are refused.
  begin
    perform integration.legacy_sync_review_decide(v_id, 'IMPORT_ANYWAY', 'validation', null);
    raise exception 'FAILED 3a: unknown action accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform integration.legacy_sync_review_decide(v_id, 'NOT_IMPORTED', ' ', null);
    raise exception 'FAILED 3b: empty decided_by accepted';
  exception when invalid_parameter_value then null; end;

  -- 4. The owner decides: recorded with who, note and fingerprint.
  perform integration.legacy_sync_review_decide(v_id, 'NOT_IMPORTED', 'validation 0014', 'test note');
  if not exists (select 1 from integration.legacy_sync_review_items where review_id=v_id and status='REJECTED'
                 and decided_by='validation 0014' and decision->>'note'='test note' and decision->>'fingerprint'='sha256:v1') then
    raise exception 'FAILED 4: decision not recorded';
  end if;

  -- 5. A decided item cannot be decided again.
  begin
    perform integration.legacy_sync_review_decide(v_id, 'FIX_IN_SOURCE', 'validation 0014', null);
    raise exception 'FAILED 5: decided twice';
  exception when object_not_in_prerequisite_state then null; end;

  -- 6. Same version again: no new item. Changed version: a new item.
  perform integration.legacy_sync_hold_for_review('FINISH_AREA','FinishEntries', v_plan, '{"row":{}}'::jsonb, null);
  if exists (select 1 from integration.legacy_sync_review_items where source_record_id='VALIDATION-0014-A' and status='OPEN') then
    raise exception 'FAILED 6a: the decided version was raised again';
  end if;
  perform integration.legacy_sync_hold_for_review('FINISH_AREA','FinishEntries',
    v_plan || jsonb_build_object('fingerprint','sha256:v2'), '{"row":{}}'::jsonb, null);
  if not exists (select 1 from integration.legacy_sync_review_items where source_record_id='VALIDATION-0014-A' and status='OPEN') then
    raise exception 'FAILED 6b: the changed version was not raised';
  end if;

  -- 7. Imported later: the open item closes when the list is read.
  insert into integration.legacy_sync_review_items(source_system, source_table, source_record_id, reason_code, raw, created_at)
  values ('CENTRALDB','User','VALIDATION-0014-B','STAFF_UNMATCHED','{"detail":"waiting"}', now() - interval '1 minute')
  returning review_id into v_id;
  insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
    target_table, target_id, source_fingerprint)
  select 'CENTRALDB','User','VALIDATION-0014-B','STAFF_MASTER','public.staff_members', s.staff_id, 'sha256:validation'
  from public.staff_members s limit 1;
  perform integration.legacy_sync_review_list();
  if not exists (select 1 from integration.legacy_sync_review_items where review_id=v_id and status='SUPERSEDED') then
    raise exception 'FAILED 7: an imported record stayed open';
  end if;

  -- 8. Client roles cannot call the new functions.
  if has_function_privilege('anon','integration.legacy_sync_review_list()','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_review_decide(uuid,text,text,text)','execute') then
    raise exception 'FAILED 8: client roles can call the review functions';
  end if;

  raise exception 'PASSED: all 8 legacy sync pending review checks (nothing was kept)';
end;
$$;
