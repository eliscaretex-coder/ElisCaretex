-- Legacy Sync: one person, two legacy user IDs (owner decision 2026-10-27).
--
-- In the legacy app, user 111 "Ryotaro" was deactivated on 2026-10-24 and the same person
-- was registered again as user 112 "Ryotaro Kawauchi". V2 has one person, created from 111.
-- The owner confirmed the correct name is "Ryotaro Kawauchi".
--
--   * new value map domain STAFF_USER_ALIAS (CENTRALDB): legacy user 111 -> 112. Value maps
--     are append-only and can only be retired;
--   * the V2 person moves from legacy_user_id 111 to 112 and is renamed "Ryotaro Kawauchi";
--   * legacy_sync_resolve_staff reads the alias first, so washes, MOP, trolley intakes and
--     attendance typed under 111 or 112 reach the same V2 person;
--   * the register sync skips user 111 (LEGACY_USER_ALIAS) instead of creating a second,
--     inactive person; user 112 is linked to the existing V2 person.

begin;

alter table integration.legacy_sync_value_maps
  drop constraint legacy_sync_value_maps_value_domain_check,
  drop constraint legacy_sync_value_maps_canonical_check;
alter table integration.legacy_sync_value_maps
  add constraint legacy_sync_value_maps_value_domain_check
    check (value_domain in ('SHIFT','FINISH_TABLE','FINISH_STATUS','WASH_ITEM_TYPE','STAFF_USER_ALIAS')),
  add constraint legacy_sync_value_maps_canonical_check check (
    (value_domain='SHIFT' and canonical_value in ('MORNING','EVENING'))
    or (value_domain='FINISH_TABLE' and canonical_value in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3'))
    or (value_domain='FINISH_STATUS' and canonical_value in ('ACTIVE','NOT_IMPORTED'))
    or (value_domain='WASH_ITEM_TYPE' and canonical_value in ('CLOTHES','MOP','NOT_IMPORTED'))
    or (value_domain='STAFF_USER_ALIAS' and canonical_value ~ '^[0-9]{1,6}$' and raw_value ~ '^[0-9]{1,6}$'
        and canonical_value <> raw_value)
  );

insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by, note)
select 'CENTRALDB', 'STAFF_USER_ALIAS', '111', '112', 'Paulo Bressan (owner)',
       'Ryotaro: legacy user 111 deactivated 2026-10-24 and registered again as 112 "Ryotaro Kawauchi". Owner confirmed 2026-10-27.'
where not exists (
  select 1 from integration.legacy_sync_value_maps m
  where m.source_system='CENTRALDB' and m.value_domain='STAFF_USER_ALIAS' and m.raw_value_key='111' and m.retired_at is null);

-- The V2 person follows the current legacy ID and the name the owner confirmed.
update public.staff_members
set legacy_user_id = 112, display_name = 'Ryotaro Kawauchi',
    row_version = row_version + 1, updated_at = now()
where legacy_user_id = 111 and deleted_at is null
  and not exists (select 1 from public.staff_members s2 where s2.legacy_user_id = 112);

create or replace function integration.legacy_sync_resolve_staff(p_user_id text, p_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_ids uuid[];
  -- A retired legacy user ID that the owner mapped to the person's current ID.
  v_user_id text := coalesce(integration.legacy_sync_map_value('CENTRALDB','STAFF_USER_ALIAS', p_user_id), p_user_id);
begin
  if p_user_id is not null then
    if v_user_id ~ '^[0-9]{1,9}$' then
      select * into v_staff from public.staff_members sm
      where sm.legacy_user_id = v_user_id::integer and sm.deleted_at is null;
    end if;
    if v_staff.staff_id is null then
      return jsonb_build_object('name', p_name, 'blockers', integration.legacy_sync_issue('STAFF_UNMAPPED', p_user_id),
        'warnings', '[]'::jsonb);
    end if;
    return jsonb_build_object('staff_id', v_staff.staff_id, 'name', v_staff.display_name, 'resolution', 'LEGACY_USER_ID',
      'blockers', '[]'::jsonb, 'warnings', '[]'::jsonb);
  end if;

  if p_name is null then
    return jsonb_build_object('name', null, 'blockers', '[]'::jsonb,
      'warnings', integration.legacy_sync_issue('PROCESSED_BY_NOT_IN_SOURCE'));
  end if;

  select array_agg(sm.staff_id) into v_ids
  from public.staff_members sm
  where sm.deleted_at is null and lower(btrim(sm.display_name)) = lower(btrim(p_name));

  if coalesce(array_length(v_ids,1),0) = 1 then
    select * into v_staff from public.staff_members sm where sm.staff_id = v_ids[1];
    return jsonb_build_object('staff_id', v_staff.staff_id, 'name', v_staff.display_name, 'resolution', 'DISPLAY_NAME',
      'blockers', '[]'::jsonb, 'warnings', '[]'::jsonb);
  end if;
  return jsonb_build_object('name', p_name, 'blockers', '[]'::jsonb,
    'warnings', integration.legacy_sync_issue(
      case when coalesce(array_length(v_ids,1),0) > 1 then 'PROCESSED_BY_NAME_AMBIGUOUS' else 'PROCESSED_BY_NAME_UNMATCHED' end,
      p_name));
end;
$$;

create or replace function integration.legacy_sync_plan_master(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_spec jsonb := integration.legacy_sync_master_spec(p_record->>'record_type');
  v_built jsonb;
  v_want jsonb;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_state integration.legacy_sync_master_states%rowtype;
  v_target uuid;
  v_via text;
  v_have jsonb;
  v_changed text[];
  v_apply text[];
  v_differs text[];
  v_action text;
  v_n integer;
  v_key text;
begin
  if v_row is null or v_spec is null then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type),'warnings','[]'::jsonb);
  end if;

  v_built := integration.legacy_sync_master_want(v_type, v_row);
  v_want := v_built->'want';
  v_blockers := v_built->'blockers';
  v_warnings := v_built->'warnings';
  v_fp := integration.legacy_sync_fingerprint(v_want);

  if v_id is null or length(v_id) > 160 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  elsif integration.legacy_sync_text(v_row, v_spec->>'id_field') is distinct from v_id then
    v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
  end if;
  if v_type = 'STAFF' and v_id !~ '^[0-9]{1,6}$' then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_USER_ID', v_id);
  end if;
  if v_type = 'DRIVER' and v_id !~ '^[0-9]{1,4}$' then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_DRIVER_ID', v_id);
  end if;
  -- A retired legacy user whose person continues under another user ID (owner decision,
  -- value map STAFF_USER_ALIAS): the V2 person follows the current ID only.
  if v_type = 'STAFF' and jsonb_array_length(v_blockers) = 0
     and integration.legacy_sync_map_value('CENTRALDB','STAFF_USER_ALIAS', v_id) is not null then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','LEGACY_USER_ALIAS',
      'alias_of', integration.legacy_sync_map_value('CENTRALDB','STAFF_USER_ALIAS', v_id),
      'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system='CENTRALDB' and l.source_table=v_spec->>'table' and l.source_record_id=v_id
    and l.link_role=v_spec->>'role' and l.source_line_key='';

  if v_link.link_id is not null then
    v_target := v_link.target_id; v_via := 'LINK';
  elsif v_id is not null then
    case v_type
      when 'STAFF' then
        if v_id ~ '^[0-9]{1,6}$' then
          select s.staff_id into v_target from public.staff_members s where s.legacy_user_id=v_id::integer;
          v_via := 'LEGACY_USER_ID';
        end if;
        if v_target is null then
          select count(*), min(s.staff_id::text)::uuid into v_n, v_target
          from public.staff_members s
          where s.legacy_user_id is null and s.deleted_at is null
            and integration.legacy_sync_name_key(s.display_name) = integration.legacy_sync_name_key(v_want->>'display_name');
          if v_n > 1 then
            v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NAME_AMBIGUOUS', v_want->>'display_name');
            v_target := null;
          end if;
          v_via := case when v_target is not null then 'NAME' end;
        end if;
      when 'CUSTOMER' then
        select c.customer_id into v_target from public.customers c
        where c.customer_code = upper(v_id) or c.legacy_metadata->>'legacy_customer_id' = v_id
        order by (c.customer_code = upper(v_id)) desc limit 1;
        v_via := 'CUSTOMER_CODE';
      when 'TROLLEY' then
        select t.trolley_id into v_target from public.trolleys t where lower(t.trolley_code) = lower(v_id);
        v_via := 'TROLLEY_CODE';
      when 'DRIVER' then
        select d.driver_id into v_target from public.distribution_drivers d
        where d.legacy_driver_id = v_id or (v_id ~ '^[0-9]{1,4}$' and d.driver_code = 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0'))
        order by (d.legacy_driver_id = v_id) desc nulls last limit 1;
        v_via := 'DRIVER_CODE';
      when 'VEHICLE' then
        select v.vehicle_id into v_target from public.fleet_vehicles v
        where upper(regexp_replace(v.registration_number, '\s', '', 'g')) = upper(regexp_replace(v_id, '\s', '', 'g'));
        v_via := 'REGISTRATION';
    end case;
  end if;

  if v_target is not null then
    v_have := integration.legacy_sync_master_have(v_type, v_target);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings,'target_id',v_target);
  end if;

  if v_target is not null and (v_have->>'deleted')::boolean then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','DELETED_IN_V2','target_id',v_target,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if v_link.link_id is not null then
    select * into v_state from integration.legacy_sync_master_states s
    where s.source_system='CENTRALDB' and s.source_table=v_spec->>'table' and s.source_record_id=v_id
    order by s.state_id desc limit 1;
    if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,
        'fingerprint',v_fp,'target_id',v_target,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
    -- Fields the legacy app changed since the last sync; of those, the ones V2 does not have yet.
    select array_agg(k order by k) into v_changed from jsonb_object_keys(v_want) k
    where k !~ '^_' and (v_want->k) is distinct from coalesce(v_state.synced->k, 'null'::jsonb);
    select array_agg(k order by k) into v_apply from unnest(coalesce(v_changed, '{}'::text[])) k
    where (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb)
      and not (k = 'product_codes' and v_want->k = 'null'::jsonb);
    v_action := case when coalesce(cardinality(v_apply),0) = 0 then 'RELINK' else 'UPDATE' end;
  elsif v_target is not null then
    v_action := case when v_via = 'NAME' then 'ADOPT_BY_NAME' else 'ADOPT' end;
    -- An empty legacy cell is not listed: only real disagreements are.
    select array_agg(k order by k) into v_differs from jsonb_object_keys(v_want) k
    where k !~ '^_' and v_want->k <> 'null'::jsonb
      and (v_want->k) is distinct from coalesce(v_have->k, 'null'::jsonb);
    if v_differs is not null then
      v_warnings := v_warnings || integration.legacy_sync_issue('V2_DIFFERS',
        (select string_agg(k || ': V2 ' || coalesce(v_have->>k,'-') || ' / legacy ' || coalesce(v_want->>k,'-'), '; ')
         from unnest(v_differs) k));
    end if;
  else
    v_action := 'CREATE';
    select array_agg(k order by k) into v_apply from jsonb_object_keys(v_want) k where k !~ '^_';
  end if;

  -- Writes V2 would refuse on its own screens.
  if v_action in ('CREATE','UPDATE') then
    if v_type = 'TROLLEY' and 'service_status' = any(v_apply) then
      if v_want->>'service_status' in ('OUT_OF_SERVICE','RETIRED') and coalesce((v_have->>'open_stay')::boolean, false) then
        v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_AT_CUSTOMER', v_want->>'service_status');
      elsif v_have->>'service_status' = 'RETIRED' then
        v_blockers := v_blockers || integration.legacy_sync_issue('TROLLEY_RETIRED_IN_V2');
      end if;
    end if;
    if v_type = 'CUSTOMER' and (v_want->>'active')::boolean and v_want->'product_codes' = 'null'::jsonb
       and (v_action = 'CREATE' or ('active' = any(v_apply) and not coalesce((v_have->>'active')::boolean, false))) then
      v_blockers := v_blockers || integration.legacy_sync_issue('SERVICE_TYPE_REQUIRED');
    end if;
    if v_type = 'DRIVER' and v_action = 'CREATE' and exists (
        select 1 from public.distribution_drivers d where d.driver_code = 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0')) then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_CODE_TAKEN', 'DRV-' || lpad(v_id, greatest(3, length(v_id)), '0'));
    end if;
    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'action',v_action,'blockers',v_blockers,'warnings',v_warnings,'target_id',v_target);
    end if;
  end if;

  return jsonb_build_object('outcome','READY','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'target_id',v_target,'matched_by',v_via,
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k,'null'::jsonb), 'legacy', v_want->k)), '{}'::jsonb)
                from unnest(coalesce(v_apply, '{}'::text[])) k),
    'want', v_want, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

revoke all on function integration.legacy_sync_resolve_staff(text,text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_master(jsonb) from public, anon, authenticated;

commit;
