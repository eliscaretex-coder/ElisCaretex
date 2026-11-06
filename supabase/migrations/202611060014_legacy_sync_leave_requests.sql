-- =====================================================================
-- ElisCaretex V2
-- Migration: 202611060014_legacy_sync_leave_requests
--
-- Eighth part of the nightly legacy sync (owner request 2026-11-06): Day Off and
-- Holiday requests are still made and decided in the legacy apps. One kind
-- "leave" with two record types:
--   * PRODUCTION_LEAVE  CentralDB LeaveRequests, one record per RequestID
--                       -> public.production_roster_leave_requests (+ events)
--   * DRIVER_LEAVE      Distribution_db "Driver Leave Requests", one record per
--                       RequestID -> public.distribution_driver_absences
--
-- Rules:
--   * the legacy request is linked to its V2 request by the last sync, else by
--     the August import (staging.legacy_leave_request_source) or by the
--     "[Legacy request: LR-…" note of the driver absences imported in October;
--   * a request V2 does not have is created with the legacy status, dates and
--     decision. Requests made in V2 are never touched;
--   * each field the legacy app changed since the last sync is written; the
--     first time a request is met the legacy values win (owner decision
--     2026-10-30), except a decision: an Approved/Rejected request in V2 is
--     never changed to another decision, or to other dates, unless the legacy
--     app changed it after the last sync and V2 did not. Otherwise it is held
--     for review (LEAVE_DECIDED_DIFFERENTLY_IN_V2);
--   * a legacy request that is still Pending never reopens a request already
--     decided in V2;
--   * an unknown person or driver waits for the registers; a request that
--     overlaps another pending/approved request of the same person in V2 is held;
--   * the email column of LeaveRequests is never sent nor stored; decision
--     actors are stored with emails masked.
--
-- New switch LEAVE_IMPORT (seeded OFF, limit 100). The Apps Script control
-- ON/OFF switches it with the others.
-- Apply after 202610300002, 202611050004 and 202611060013.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('integration.legacy_sync_import_roster(uuid,jsonb)') is null then
    raise exception 'Apply 202610300002_legacy_sync_rosters.sql first.';
  end if;
  if to_regprocedure('public.mask_emails_in_text(text)') is null then
    raise exception 'Apply 202611050004_users_permissions_privacy_hardening.sql first.';
  end if;
end;
$$;

insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('LEAVE_IMPORT', false, 100, 'migration 202611060014',
        'Seeded disabled. Production and driver Day Off / Holiday requests. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

-- ---------------------------------------------------------------------
-- 1. Legacy values
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_leave_type(p_value text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case when nullif(btrim(coalesce(p_value, '')), '') is null then null
              else regexp_replace(upper(btrim(p_value)), '[^A-Z0-9]+', '_', 'g') end;
$$;

-- Legacy status -> V2 status (production PENDING, drivers REQUESTED). Null when unknown.
create or replace function integration.legacy_sync_leave_status(p_value text, p_driver boolean)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case lower(btrim(coalesce(p_value, '')))
    when 'pending' then case when p_driver then 'REQUESTED' else 'PENDING' end
    when 'requested' then case when p_driver then 'REQUESTED' else 'PENDING' end
    when 'approved' then 'APPROVED'
    when 'rejected' then 'REJECTED'
    when 'declined' then 'REJECTED'
    when 'cancelled' then 'CANCELLED'
    when 'canceled' then 'CANCELLED'
    else null end;
$$;

-- One legacy request as a flat map, with the person it belongs to.
create or replace function integration.legacy_sync_leave_want(p_type text, p_row jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_driver boolean := p_type = 'DRIVER_LEAVE';
  v_person text := integration.legacy_sync_text(p_row, case when v_driver then 'DriverID' else 'UserID' end);
  v_kind text := integration.legacy_sync_leave_type(integration.legacy_sync_text(p_row, case when v_driver then 'LeaveType' else 'Type' end));
  v_start date := integration.legacy_sync_parse_date(integration.legacy_sync_text(p_row, 'StartDate'));
  v_end date := integration.legacy_sync_parse_date(integration.legacy_sync_text(p_row, 'EndDate'));
  v_raw_status text := integration.legacy_sync_text(p_row, 'Status');
  v_status text := integration.legacy_sync_leave_status(integration.legacy_sync_text(p_row, 'Status'), p_type = 'DRIVER_LEAVE');
  v_target_id uuid;
  v_name text;
  v_want jsonb;
  v_blockers jsonb := '[]'::jsonb;
begin
  v_person := case when v_person ~ '^[0-9]+(\.0+)?$' then split_part(v_person, '.', 1) end;
  if not v_driver and v_person is not null then
    v_person := coalesce(integration.legacy_sync_map_value('CENTRALDB', 'STAFF_USER_ALIAS', v_person), v_person);
  end if;
  v_end := coalesce(v_end, v_start);

  if v_person is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_LEAVE_PERSON',
      integration.legacy_sync_text(p_row, case when v_driver then 'DriverName' else 'Name' end));
  elsif v_driver then
    select d.driver_id, d.display_name into v_target_id, v_name from public.distribution_drivers d
    where d.legacy_driver_id = v_person and d.deleted_at is null limit 1;
    if v_target_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_NOT_IN_V2',
        v_person || ' ' || coalesce(integration.legacy_sync_text(p_row, 'DriverName'), ''));
    end if;
  else
    select sm.staff_id, sm.display_name into v_target_id, v_name from public.staff_members sm
    where sm.legacy_user_id = v_person::integer and sm.deleted_at is null;
    if v_target_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NOT_IN_V2',
        v_person || ' ' || coalesce(integration.legacy_sync_text(p_row, 'Name'), ''));
    end if;
  end if;

  if v_kind is null or (not v_driver and v_kind not in ('DAY_OFF','HOLIDAY')) then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_LEAVE_TYPE',
      integration.legacy_sync_text(p_row, case when v_driver then 'LeaveType' else 'Type' end));
  end if;
  if v_start is null or v_end < v_start or (not v_driver and v_kind = 'DAY_OFF' and v_end <> v_start) then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_LEAVE_DATES',
      concat_ws(' - ', integration.legacy_sync_text(p_row, 'StartDate'), integration.legacy_sync_text(p_row, 'EndDate')));
  end if;
  if v_status is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_LEAVE_STATUS', v_raw_status);
  end if;

  if v_driver then
    v_want := jsonb_build_object(
      'person', v_person, 'type', v_kind, 'start', v_start, 'end', v_end,
      'notes', nullif(btrim(coalesce(integration.legacy_sync_text(p_row, 'Notes'), '')), ''),
      'status', v_status,
      'decided_by', public.mask_emails_in_text(integration.legacy_sync_text(p_row, 'ReviewedBy')),
      'decision_note', left(public.mask_emails_in_text(integration.legacy_sync_text(p_row, 'DecisionNotes')), 500),
      'source', integration.legacy_sync_text(p_row, 'Source'));
  else
    v_want := jsonb_build_object(
      'person', v_person, 'type', v_kind, 'start', v_start, 'end', v_end,
      'reason', left(public.mask_emails_in_text(nullif(btrim(coalesce(integration.legacy_sync_text(p_row, 'Reason'), '')), '')), 280),
      'status', v_status,
      'submitted_at', integration.legacy_sync_parse_instant(integration.legacy_sync_text(p_row, 'SubmittedAt')),
      'decided_at', case when v_status in ('APPROVED','REJECTED','CANCELLED')
                         then integration.legacy_sync_parse_instant(integration.legacy_sync_text(p_row, 'DecidedAt')) end,
      'decided_by', case when v_status in ('APPROVED','REJECTED','CANCELLED')
                         then public.mask_emails_in_text(integration.legacy_sync_text(p_row, 'DecidedBy')) end,
      'decision_note', left(public.mask_emails_in_text(integration.legacy_sync_text(p_row, 'DecisionNote')), 500));
  end if;

  return jsonb_build_object('want', jsonb_strip_nulls(v_want), 'owner_id', v_target_id, 'owner_name', v_name,
    'blockers', v_blockers);
end;
$$;

-- What V2 holds for one linked request, in the same flat map.
create or replace function integration.legacy_sync_leave_have(p_type text, p_target uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  select case when p_type = 'DRIVER_LEAVE' then (
    select jsonb_strip_nulls(jsonb_build_object('person', d.legacy_driver_id, 'type', a.absence_type,
      'start', a.starts_on, 'end', a.ends_on,
      'notes', nullif(btrim(regexp_replace(coalesce(a.notes, ''), '\n?\[Legacy request: [^\]]*\]\s*$', '')), ''),
      'status', a.absence_status))
    from public.distribution_driver_absences a join public.distribution_drivers d on d.driver_id = a.driver_id
    where a.absence_id = p_target)
  else (
    select jsonb_strip_nulls(jsonb_build_object('person', sm.legacy_user_id::text, 'type', r.request_type,
      'start', r.start_date, 'end', r.end_date, 'reason', nullif(btrim(r.reason), ''), 'status', r.status,
      'submitted_at', r.submitted_at, 'decided_at', r.reviewed_at, 'decided_by', r.decision_actor,
      'decision_note', nullif(btrim(r.review_note), '')))
    from public.production_roster_leave_requests r join public.staff_members sm on sm.staff_id = r.staff_id
    where r.leave_request_id = p_target)
  end;
$$;

-- ---------------------------------------------------------------------
-- 2. Plan for one request. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_leave(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_type text := upper(coalesce(p_record->>'record_type', ''));
  v_row jsonb := case when jsonb_typeof(p_record->'row') = 'object' then p_record->'row' end;
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_driver boolean := upper(coalesce(p_record->>'record_type', '')) = 'DRIVER_LEAVE';
  v_system text := case when upper(coalesce(p_record->>'record_type', '')) = 'DRIVER_LEAVE' then 'DISTRIBUTIONDB' else 'CENTRALDB' end;
  v_table text := case when upper(coalesce(p_record->>'record_type', '')) = 'DRIVER_LEAVE' then 'Driver Leave Requests' else 'LeaveRequests' end;
  v_built jsonb;
  v_want jsonb;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_state integration.legacy_sync_master_states%rowtype;
  v_target uuid;
  v_have jsonb := '{}'::jsonb;
  v_base jsonb;
  v_keys text[] := case when upper(coalesce(p_record->>'record_type', '')) = 'DRIVER_LEAVE'
                        then array['type','start','end','notes','status']
                        else array['type','start','end','reason','status','decision_note'] end;
  v_apply text[];
  v_merged jsonb;
  v_action text;
  v_decided text[];
  v_k text;
begin
  if v_type not in ('PRODUCTION_LEAVE','DRIVER_LEAVE') or v_row is null or v_id is null then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type),'warnings','[]'::jsonb);
  end if;
  v_decided := array['APPROVED','REJECTED','CANCELLED'];

  v_built := integration.legacy_sync_leave_want(v_type, v_row);
  v_want := v_built->'want';
  v_blockers := v_built->'blockers';
  v_fp := integration.legacy_sync_fingerprint(v_want);

  select * into v_state from integration.legacy_sync_master_states s
  where s.source_system = v_system and s.source_table = v_table and s.source_record_id = v_id
  order by s.state_id desc limit 1;
  if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
    return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,
      'fingerprint',v_fp,'target_id',v_state.target_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings);
  end if;

  -- The V2 request: last sync, else the earlier imports.
  if v_state.state_id is not null then
    v_target := v_state.target_id;
    v_base := v_state.synced;
  elsif v_driver then
    select a.absence_id into v_target from public.distribution_driver_absences a
    where a.notes like '%[Legacy request: ' || v_id || ';%' or a.notes like '%[Legacy request: ' || v_id || ']%'
    order by a.created_at limit 1;
  else
    select r.leave_request_id into v_target from staging.legacy_leave_request_source s
    join public.production_roster_leave_requests r on r.leave_request_id = s.target_leave_request_id
    where s.legacy_request_id = v_id order by s.source_batch desc limit 1;
  end if;
  if v_target is not null then
    v_have := coalesce(integration.legacy_sync_leave_have(v_type, v_target), '{}'::jsonb);
    if v_have = '{}'::jsonb then
      v_target := null;
    elsif v_have->>'person' is distinct from v_want->>'person' then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers', integration.legacy_sync_issue('LEAVE_PERSON_DIFFERS_IN_V2',
          coalesce(v_have->>'person','-') || ' / legacy ' || (v_want->>'person')),'warnings',v_warnings);
    end if;
  end if;

  select array_agg(k order by k) into v_apply from unnest(v_keys) k
  where coalesce(v_want->k, 'null'::jsonb) is distinct from coalesce(v_have->k, 'null'::jsonb)
    and (v_base is null or coalesce(v_want->k, 'null'::jsonb) is distinct from coalesce(v_base->k, 'null'::jsonb));

  if v_target is not null and v_apply is not null then
    -- A request still pending in the legacy app never reopens a decision taken in V2.
    if 'status' = any(v_apply) and v_want->>'status' in ('PENDING','REQUESTED') and v_have->>'status' = any(v_decided) then
      v_apply := array_remove(v_apply, 'status');
      v_warnings := v_warnings || integration.legacy_sync_issue('DECIDED_IN_V2_FIRST', v_have->>'status');
    end if;
    -- A decided V2 request changes decision or dates only when V2 kept what the last sync wrote.
    if v_have->>'status' = any(v_decided) and v_apply && array['status','type','start','end']
       and (v_base is null or exists (
             select 1 from unnest(array['status','type','start','end']) k
             where coalesce(v_have->k, 'null'::jsonb) is distinct from coalesce(v_base->k, 'null'::jsonb))) then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers', integration.legacy_sync_issue('LEAVE_DECIDED_DIFFERENTLY_IN_V2',
          'V2 ' || (v_have->>'status') || ' ' || (v_have->>'start') || '..' || (v_have->>'end')
          || ' / legacy ' || (v_want->>'status') || ' ' || (v_want->>'start') || '..' || (v_want->>'end')),
        'warnings',v_warnings);
    end if;
    if cardinality(v_apply) = 0 then
      v_apply := null;
    end if;
  end if;

  v_merged := v_have;
  foreach v_k in array coalesce(v_apply, '{}'::text[]) loop
    v_merged := case when v_want ? v_k then v_merged || jsonb_build_object(v_k, v_want->v_k) else v_merged - v_k end;
  end loop;
  if v_target is null then
    v_merged := v_want;
  elsif 'status' = any(coalesce(v_apply, '{}'::text[])) then
    -- A new decision comes with who took it and when.
    v_merged := (v_merged - 'decided_at' - 'decided_by')
      || jsonb_strip_nulls(jsonb_build_object('decided_at', v_want->'decided_at', 'decided_by', v_want->'decided_by'));
  end if;
  -- The legacy reference kept in a driver absence note always names the legacy source.
  v_merged := v_merged || jsonb_strip_nulls(jsonb_build_object('source', v_want->'source'));

  v_action := case when v_target is null then 'CREATE'
                   when v_apply is not null then 'UPDATE'
                   when v_state.state_id is null then 'ADOPT' else 'RELINK' end;

  -- Same checks as a request made in V2: one pending/approved request per person and day.
  if v_action = 'CREATE' or (v_action = 'UPDATE' and v_apply && array['status','start','end']) then
    if v_merged->>'status' in ('PENDING','REQUESTED','APPROVED') then
      if v_driver then
        select v_blockers || coalesce(jsonb_agg(i), '[]'::jsonb)
        into v_blockers
        from public.distribution_driver_absences a
        cross join lateral jsonb_array_elements(integration.legacy_sync_issue('LEAVE_OVERLAPS_IN_V2',
                 a.absence_type || ' ' || a.starts_on || '..' || a.ends_on || ' ' || a.absence_status)) i
        where a.driver_id = (v_built->>'owner_id')::uuid and a.absence_id is distinct from v_target
          and a.absence_status in ('REQUESTED','APPROVED')
          and daterange(a.starts_on, a.ends_on, '[]') && daterange((v_merged->>'start')::date, (v_merged->>'end')::date, '[]');
      else
        select v_blockers || coalesce(jsonb_agg(i), '[]'::jsonb)
        into v_blockers
        from public.production_roster_leave_requests r
        cross join lateral jsonb_array_elements(integration.legacy_sync_issue('LEAVE_OVERLAPS_IN_V2',
                 r.request_type || ' ' || r.start_date || '..' || r.end_date || ' ' || r.status)) i
        where r.staff_id = (v_built->>'owner_id')::uuid and r.leave_request_id is distinct from v_target
          and r.status in ('PENDING','APPROVED')
          and daterange(r.start_date, r.end_date, '[]') && daterange((v_merged->>'start')::date, (v_merged->>'end')::date, '[]');
      end if;
    end if;
    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'action',v_action,'blockers',v_blockers,'warnings',v_warnings,'target_id',v_target);
    end if;
  end if;

  return jsonb_build_object('outcome','READY','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'target_id',v_target,'owner_id',v_built->'owner_id','owner_name',v_built->'owner_name',
    'baseline', case when v_state.state_id is not null then 'LAST_SYNC' else 'LEGACY_WINS_FIRST_TIME' end,
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k, 'null'::jsonb),
                                                                         'legacy', coalesce(v_want->k, 'null'::jsonb))), '{}'::jsonb)
                from unnest(coalesce(v_apply, '{}'::text[])) k),
    'want', v_want, 'merged', v_merged, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

create or replace function integration.legacy_sync_leave_dry_run(p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_record jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array'
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 60 then
    raise exception using errcode='22023', message='Send between 1 and 60 legacy leave records.';
  end if;
  for v_record in select value from jsonb_array_elements(p_records) loop
    v_out := v_out || jsonb_build_array(integration.legacy_sync_plan_leave(v_record) - 'want' - 'merged');
  end loop;
  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Writers
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_leave_write_production(
  p_target uuid, p_owner uuid, p_merged jsonb, p_changes jsonb, p_legacy_id text)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_request public.production_roster_leave_requests%rowtype;
  v_old public.production_roster_leave_requests%rowtype;
  v_threshold integer := greatest(1, coalesce((public.production_roster_leave_governance_settings_value()->>'general_manager_threshold_days')::integer, 20));
  v_status text := p_merged->>'status';
  v_decided boolean := p_merged->>'status' in ('APPROVED','REJECTED','CANCELLED');
  v_source text := case when lower(coalesce(p_merged->>'decided_by', '')) like '%general manager%' then 'GENERAL_MANAGER'
                        when lower(coalesce(p_merged->>'decided_by', '')) like '%system%' then 'SYSTEM' else 'MANAGER' end;
begin
  if p_target is null then
    insert into public.production_roster_leave_requests(staff_id, staff_display_name_snapshot, request_type, start_date,
      end_date, reason, status, submitted_at, reviewed_at, review_note, source_application, requires_general_manager,
      gm_threshold_days_snapshot, decision_source, decision_actor)
    select sm.staff_id, sm.display_name, p_merged->>'type', (p_merged->>'start')::date, (p_merged->>'end')::date,
      p_merged->>'reason', v_status, coalesce((p_merged->>'submitted_at')::timestamptz, now()),
      case when v_decided then coalesce((p_merged->>'decided_at')::timestamptz, now()) end,
      p_merged->>'decision_note', 'LEGACY_SYNC',
      p_merged->>'type' = 'HOLIDAY' and ((p_merged->>'end')::date - (p_merged->>'start')::date + 1) > v_threshold,
      v_threshold, case when v_decided then v_source end,
      case when v_decided then coalesce(p_merged->>'decided_by', 'Legacy app') end
    from public.staff_members sm where sm.staff_id = p_owner
    returning * into v_request;
    perform public.record_production_roster_leave_event(v_request.leave_request_id, 'LEGACY_SYNC_IMPORTED',
      'Legacy sync', 'SYSTEM', null, v_status, null,
      jsonb_build_object('legacy_request_id', p_legacy_id, 'decided_by', p_merged->>'decided_by',
                         'decided_at', p_merged->>'decided_at'));
    return v_request.leave_request_id;
  end if;

  select * into v_old from public.production_roster_leave_requests where leave_request_id = p_target for update;
  update public.production_roster_leave_requests r set
    request_type = p_merged->>'type',
    start_date = (p_merged->>'start')::date,
    end_date = (p_merged->>'end')::date,
    reason = p_merged->>'reason',
    review_note = p_merged->>'decision_note',
    status = v_status,
    reviewed_at = case when p_changes ? 'status' and v_decided then coalesce((p_merged->>'decided_at')::timestamptz, now())
                       when p_changes ? 'status' then null else r.reviewed_at end,
    reviewed_by = case when p_changes ? 'status' then null else r.reviewed_by end,
    decision_source = case when p_changes ? 'status' and v_decided then v_source
                           when p_changes ? 'status' then null else r.decision_source end,
    decision_actor = case when p_changes ? 'status' and v_decided then coalesce(p_merged->>'decided_by', 'Legacy app')
                          when p_changes ? 'status' then null else r.decision_actor end
  where r.leave_request_id = p_target
  returning * into v_request;
  if v_status in ('REJECTED','CANCELLED') and v_old.status is distinct from v_status then
    update public.production_roster_leave_gm_reviews
    set state = 'CANCELLED', decision = 'REJECTED', decided_at = now(),
        decision_note = 'Decided in the legacy app.', updated_at = now()
    where leave_request_id = p_target and state not in ('DECIDED', 'CANCELLED');
  end if;
  perform public.record_production_roster_leave_event(p_target, 'LEGACY_SYNC_UPDATED', 'Legacy sync', 'SYSTEM',
    v_old.status, v_request.status, null,
    jsonb_build_object('legacy_request_id', p_legacy_id, 'changes', p_changes, 'decided_by', p_merged->>'decided_by'));
  return p_target;
end;
$$;

create or replace function integration.legacy_sync_leave_write_driver(
  p_target uuid, p_owner uuid, p_merged jsonb, p_changes jsonb, p_legacy_id text)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_row public.distribution_driver_absences%rowtype;
  v_notes text := left(concat_ws(E'\n', p_merged->>'notes',
    '[Legacy request: ' || p_legacy_id || '; Reviewed by: ' || coalesce(p_merged->>'decided_by', 'n/a')
    || '; Source: ' || coalesce(p_merged->>'source', 'legacy') || ']'), 2000);
begin
  if p_target is null then
    insert into public.distribution_driver_absences(driver_id, absence_type, starts_on, ends_on, absence_status, notes)
    values (p_owner, p_merged->>'type', (p_merged->>'start')::date, (p_merged->>'end')::date, p_merged->>'status', v_notes)
    returning * into v_row;
  else
    update public.distribution_driver_absences a set
      absence_type = p_merged->>'type', starts_on = (p_merged->>'start')::date, ends_on = (p_merged->>'end')::date,
      absence_status = p_merged->>'status', notes = v_notes, updated_by = null, updated_at = now(),
      row_version = a.row_version + 1
    where a.absence_id = p_target
    returning * into v_row;
  end if;

  -- As review_driver_leave_request: an approved absence leaves the open Distribution drafts.
  if v_row.absence_status = 'APPROVED' and (p_target is null or p_changes ?| array['status','start','end']) then
    update public.distribution_roster_entries e set
      support_driver_id = null, support_driver_name_snapshot = null, updated_at = now(), updated_by = null,
      row_version = e.row_version + 1
    from public.distribution_roster_versions v
    where v.distribution_roster_version_id = e.distribution_roster_version_id and v.roster_status = 'DRAFT'
      and e.support_driver_id = v_row.driver_id and e.primary_driver_id is distinct from v_row.driver_id
      and e.work_date between v_row.starts_on and v_row.ends_on;
    delete from public.distribution_roster_entries e using public.distribution_roster_versions v
    where v.distribution_roster_version_id = e.distribution_roster_version_id and v.roster_status = 'DRAFT'
      and e.primary_driver_id = v_row.driver_id and e.work_date between v_row.starts_on and v_row.ends_on;
  end if;
  return v_row.absence_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Importer
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_leave_one(
  p_sync_run_id uuid,
  p_record jsonb,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_LEAVE';
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_system text := case when upper(coalesce(p_record->>'record_type','')) = 'DRIVER_LEAVE' then 'DISTRIBUTIONDB' else 'CENTRALDB' end;
  v_table text := case when upper(coalesce(p_record->>'record_type','')) = 'DRIVER_LEAVE' then 'Driver Leave Requests' else 'LeaveRequests' end;
  v_plan jsonb;
  v_id text;
  v_action text;
  v_target uuid;
  v_done integer;
begin
  if v_type not in ('PRODUCTION_LEAVE','DRIVER_LEAVE') then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',p_record->>'source_record_id',
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_LEAVE:' || v_type || ':' || lower(coalesce(p_record->>'source_record_id','')), 0));
  v_plan := integration.legacy_sync_plan_leave(p_record);
  v_id := v_plan->>'source_record_id';
  if v_plan->>'outcome' = 'ALREADY_IMPORTED' then
    return v_plan;
  end if;
  perform integration.legacy_sync_keep_version(v_system, v_table, v_id, v_plan->>'fingerprint', p_record->'row', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(v_system, v_table, v_plan, p_record, p_sync_run_id);
    return v_plan - 'want' - 'merged';
  end if;

  v_action := v_plan->>'action';
  v_target := nullif(v_plan->>'target_id','')::uuid;

  if v_action in ('CREATE','UPDATE') then
    select count(*) into v_done from public.audit_log a
    where a.correlation_id = p_sync_run_id and a.source_application = c_source;
    if v_done >= p_limit then
      return jsonb_build_object('outcome','RUN_LIMIT_REACHED','record_type',v_type,'source_record_id',v_id,
        'max_entries_per_run',p_limit);
    end if;

    if v_type = 'DRIVER_LEAVE' then
      v_target := integration.legacy_sync_leave_write_driver(v_target, (v_plan->>'owner_id')::uuid, v_plan->'merged',
        v_plan->'changes', v_id);
    else
      v_target := integration.legacy_sync_leave_write_production(v_target, (v_plan->>'owner_id')::uuid, v_plan->'merged',
        v_plan->'changes', v_id);
    end if;
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values (case when v_type = 'DRIVER_LEAVE' then 'DRIVER_LEAVE_' else 'PRODUCTION_ROSTER_LEAVE_REQUEST_' end
              || case when v_action = 'CREATE' then 'IMPORTED' else 'UPDATED' end,
      case when v_type = 'DRIVER_LEAVE' then 'distribution_driver_absences' else 'production_roster_leave_requests' end,
      v_target::text, case when v_action = 'UPDATE' then (select jsonb_object_agg(k, c->'v2') from jsonb_each(v_plan->'changes') x(k, c)) end,
      jsonb_build_object('legacy_request_id', v_id, 'person', v_plan->>'owner_name', 'baseline', v_plan->>'baseline')
        || ((v_plan->'merged') - 'person'),
      left('Legacy sync: ' || v_table || ' ' || v_id || case when v_action = 'CREATE' then ' imported.' else ' changed in the legacy app.' end, 500),
      c_source, p_sync_run_id);
  end if;

  insert into integration.legacy_sync_master_states(source_system, source_table, source_record_id, target_table,
    target_id, action, synced, source_fingerprint, sync_run_id)
  values (v_system, v_table, v_id,
    case when v_type = 'DRIVER_LEAVE' then 'public.distribution_driver_absences' else 'public.production_roster_leave_requests' end,
    v_target, v_action, v_plan->'want', v_plan->>'fingerprint', p_sync_run_id);

  return (v_plan - 'want' - 'merged') || jsonb_build_object('outcome',
    case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' when 'RELINK' then 'RELINKED' else 'ADOPTED' end,
    'imported', true, 'target_id', v_target);
end;
$$;

create or replace function integration.legacy_sync_import_leave(
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
  v_records jsonb;
  v_record jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='LEAVE_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy leave import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  if jsonb_typeof(p_record->'records') = 'array' then
    v_records := p_record->'records';
    if jsonb_array_length(v_records) = 0 or jsonb_array_length(v_records) > 60 then
      raise exception using errcode='22023', message='Send between 1 and 60 legacy leave records.';
    end if;
  else
    v_records := jsonb_build_array(p_record);
  end if;

  for v_record in select value from jsonb_array_elements(v_records) loop
    begin
      v_result := integration.legacy_sync_import_leave_one(p_sync_run_id, v_record, v_setting.max_entries_per_run);
    exception when others then
      v_result := jsonb_build_object('outcome','ERROR','record_type',upper(coalesce(v_record->>'record_type','')),
        'source_record_id', v_record->>'source_record_id', 'sqlstate', sqlstate, 'error', left(sqlerrm, 300));
    end;
    v_results := v_results || jsonb_build_array(v_result);
    exit when v_result->>'outcome' = 'RUN_LIMIT_REACHED';
  end loop;

  if jsonb_typeof(p_record->'records') <> 'array' or p_record->'records' is null then
    return v_results->0;
  end if;
  return jsonb_build_object('outcome','BATCH','records',jsonb_array_length(v_results),
    'counts', (select coalesce(jsonb_object_agg(o, n), '{}'::jsonb) from (
        select r->>'outcome' as o, count(*) as n from jsonb_array_elements(v_results) r group by 1) x),
    'results', v_results);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Dispatchers: add the kind "leave" (keeps the schedule resync of 202611060013).
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
    when 'attendance' then return integration.legacy_sync_attendance_dry_run(p_records);
    when 'master' then return integration.legacy_sync_master_dry_run(p_records);
    when 'schedule' then return integration.legacy_sync_schedule_dry_run(p_records);
    when 'roster' then return integration.legacy_sync_roster_dry_run(p_records);
    when 'leave' then return integration.legacy_sync_leave_dry_run(p_records);
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
declare
  v_result jsonb;
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_import_wash(p_sync_run_id, p_record);
    when 'mop' then return integration.legacy_sync_import_mop(p_sync_run_id, p_record);
    when 'trolley' then return integration.legacy_sync_import_trolley(p_sync_run_id, p_record);
    when 'attendance' then return integration.legacy_sync_import_attendance(p_sync_run_id, p_record);
    when 'master' then return integration.legacy_sync_import_master(p_sync_run_id, p_record);
    when 'schedule' then
      -- One resync of the open route runs for the whole batch (202611060013).
      perform set_config('app.defer_distribution_resync', 'on', true);
      v_result := integration.legacy_sync_import_schedule(p_sync_run_id, p_record);
      perform set_config('app.defer_distribution_resync', '', true);
      perform public.distribution_resync_open_runs();
      return v_result;
    when 'roster' then return integration.legacy_sync_import_roster(p_sync_run_id, p_record);
    when 'leave' then return integration.legacy_sync_import_leave(p_sync_run_id, p_record);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_leave_type(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_status(text, boolean) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_want(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_have(text, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_leave(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_write_production(uuid, uuid, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_leave_write_driver(uuid, uuid, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_leave_one(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_leave(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_leave_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_leave(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_leave(jsonb) is
  'Read-only plan for one legacy Day Off / Holiday request (production or driver): create, fields the legacy app changed since the last sync, or hold.';
comment on function integration.legacy_sync_import_leave(uuid, jsonb) is
  'Imports legacy production and driver leave requests inside an open COMMIT run, when LEAVE_IMPORT is enabled. service_role only.';

commit;
