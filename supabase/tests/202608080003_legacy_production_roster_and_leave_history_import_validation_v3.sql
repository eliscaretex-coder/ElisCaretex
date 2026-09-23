-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080003 legacy roster + leave history import — v3
-- Read-only assertions inside BEGIN/ROLLBACK.
-- =====================================================================

begin;

do $$
declare
  v_count integer;
  v_bad integer;
begin
  if to_regclass('staging.legacy_production_roster_source') is null
     or to_regclass('staging.legacy_leave_request_source') is null then
    raise exception 'Legacy import staging tables are missing.';
  end if;

  select count(*) into v_count
  from staging.legacy_production_roster_source
  where source_batch='LEGACY_ROSTER_20260808';
  if v_count<>50 then
    raise exception 'Expected 50 legacy roster snapshots, found %.',v_count;
  end if;

  select coalesce(sum(source_entry_count),0) into v_count
  from staging.legacy_production_roster_source
  where source_batch='LEGACY_ROSTER_20260808';
  if v_count<>8186 then
    raise exception 'Expected 8186 reconstructed legacy roster entries, found %.',v_count;
  end if;

  select coalesce(sum(implicit_default_count),0) into v_count
  from staging.legacy_production_roster_source
  where source_batch='LEGACY_ROSTER_20260808';
  if v_count<>788 then
    raise exception 'Expected 788 implicit legacy defaults, found %.',v_count;
  end if;

  select count(*) into v_count
  from staging.legacy_production_roster_source s
  cross join lateral jsonb_array_elements(s.source_payload->'e') e(value)
  where s.source_batch='LEGACY_ROSTER_20260808'
    and (e.value->>2) in ('W','Q','C')
    and (e.value->>3) in ('SUP','CLN','SR');
  if v_count<>409 then
    raise exception 'Expected 409 role-only working/quality/cover rows requiring V2 area compatibility, found %.',v_count;
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source
  where source_batch='LEGACY_ROSTER_20260808'
    and week_start>date '2026-08-03';
  if v_bad<>0 then
    raise exception 'Future legacy roster weeks were staged as official history.';
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source s
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status not in ('IMPORTED','SKIPPED_EXISTING_PUBLISHED');
  if v_bad<>0 then
    raise exception 'Roster source rows remain in unexpected import state: %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source s
  join public.production_roster_versions prv
    on prv.roster_version_id=s.imported_roster_version_id
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status='IMPORTED'
    and prv.status<>'PUBLISHED';
  if v_bad<>0 then
    raise exception 'Imported legacy roster version is not PUBLISHED.';
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source s
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status='IMPORTED'
    and (
      select count(*)
      from public.production_roster_entries pre
      where pre.roster_version_id=s.imported_roster_version_id
    )<>s.source_entry_count;
  if v_bad<>0 then
    raise exception 'Imported legacy roster entry count mismatch.';
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source s
  join public.production_roster_entries pre
    on pre.roster_version_id=s.imported_roster_version_id
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status='IMPORTED'
    and pre.day_status in ('WORKING','QUALITY_ANALYSIS')
    and pre.display_section_code in ('SUPERVISOR','CLEANER','SUPPORT_ROLE')
    and pre.area_id is null;
  if v_bad<>0 then
    raise exception 'Imported legacy role-only working rows still have NULL area_id: %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_production_roster_source s
  join public.production_roster_events ev
    on ev.roster_version_id=s.imported_roster_version_id
   and ev.event_type='PUBLISHED'
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status='IMPORTED'
    and coalesce(ev.metadata->'role_only_area_compatibility'->>'v2_area_code','')<>'FINISH';
  if v_bad<>0 then
    raise exception 'Legacy role-only compatibility provenance is missing from imported roster events.';
  end if;

  select count(*) into v_count
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808';
  if v_count<>57 then
    raise exception 'Expected 57 legacy leave requests, found %.',v_count;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808'
    and (
      (final_status='APPROVED' and decision_basis='EXPLICIT')
      or false
    );
  if v_bad<>39 then
    raise exception 'Expected 39 explicit approved requests, found %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808'
    and final_status='APPROVED'
    and decision_basis='ROSTER_INFERRED';
  if v_bad<>2 then
    raise exception 'Expected 2 roster-inferred approvals, found %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808'
    and final_status='REJECTED';
  if v_bad<>8 then
    raise exception 'Expected 8 rejected requests, found %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808'
    and final_status='PENDING';
  if v_bad<>8 then
    raise exception 'Expected 8 unresolved/pending requests, found %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source
  where source_batch='LEGACY_ROSTER_20260808'
    and import_status not in ('IMPORTED','ALREADY_IMPORTED','SKIPPED_EXISTING_EQUIVALENT');
  if v_bad<>0 then
    raise exception 'Leave source rows remain in unexpected import state: %.',v_bad;
  end if;

  select count(*) into v_bad
  from staging.legacy_leave_request_source s
  join public.production_roster_leave_requests r
    on r.leave_request_id=s.imported_leave_request_id
  where s.source_batch='LEGACY_ROSTER_20260808'
    and s.import_status in ('IMPORTED','ALREADY_IMPORTED')
    and (
      r.staff_id<>(select sm.staff_id from public.staff_members sm where sm.legacy_user_id=s.legacy_user_id and sm.deleted_at is null)
      or r.request_type<>s.request_type
      or r.start_date<>s.start_date
      or r.end_date<>s.end_date
    );
  if v_bad<>0 then
    raise exception 'Imported leave request does not match its legacy source identity/date.';
  end if;

  if has_table_privilege('anon','staging.legacy_production_roster_source','SELECT')
     or has_table_privilege('authenticated','staging.legacy_production_roster_source','SELECT')
     or has_table_privilege('anon','staging.legacy_leave_request_source','SELECT')
     or has_table_privilege('authenticated','staging.legacy_leave_request_source','SELECT') then
    raise exception 'Legacy staging tables are exposed to browser roles.';
  end if;

  if has_table_privilege('authenticated','public.production_roster_leave_requests','SELECT')
     or has_table_privilege('authenticated','public.production_roster_leave_request_events','SELECT') then
    raise exception 'Private leave tables gained direct authenticated SELECT.';
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608080003_legacy_production_roster_and_leave_history_import_validation_v3',
  'source_batch','LEGACY_ROSTER_20260808',
  'historical_roster_snapshots',50,
  'historical_weeks',25,
  'reconstructed_roster_entries',8186,
  'implicit_default_entries',788,
  'role_only_area_compatibility_source_entries',409,
  'role_only_area_compatibility_area','FINISH',
  'leave_requests',57,
  'explicit_approved',39,
  'roster_inferred_approved',2,
  'rejected',8,
  'pending',8,
  'future_legacy_rosters_not_published',true,
  'existing_v2_published_rosters_preserved',true,
  'equivalent_v2_leave_requests_not_duplicated',true,
  'private_staging',true,
  'writes_rolled_back',true
);

rollback;
