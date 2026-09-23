-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100006_sorting_staff_cards_time_and_work_mode_audit
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.active=true
    join public.roles r on r.role_id=sr.role_id and r.active=true and r.role_code='ADMIN'
    where sm.auth_user_id is not null and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

do $$
declare
  v_shift text;
  v_context jsonb;
  v_a uuid;
  v_b uuid;
begin
  for v_shift in select unnest(array['MORNING','EVENING']) loop
    v_context := public.get_sorting_staff_work_context_v2(v_shift);
    if jsonb_array_length(coalesce(v_context->'staff','[]'::jsonb)) >= 2 then
      exit;
    end if;
  end loop;

  select nullif(value->>'staff_id','')::uuid
  into v_a
  from jsonb_array_elements(coalesce(v_context->'staff','[]'::jsonb))
  order by value->>'display_name'
  limit 1;

  select nullif(value->>'staff_id','')::uuid
  into v_b
  from jsonb_array_elements(coalesce(v_context->'staff','[]'::jsonb))
  where nullif(value->>'staff_id','')::uuid <> v_a
  order by value->>'display_name'
  limit 1;

  if v_a is null or v_b is null then
    raise exception 'Need two current Sorting staff for work-mode validation.';
  end if;

  perform set_config('eliscaretex.validation.shift',v_shift,true);
  perform set_config('eliscaretex.validation.a',v_a::text,true);
  perform set_config('eliscaretex.validation.b',v_b::text,true);
end;
$$;

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.validation.shift');
  v_a uuid := current_setting('eliscaretex.validation.a')::uuid;
  v_b uuid := current_setting('eliscaretex.validation.b')::uuid;
  v_result jsonb;
  v_context jsonb;
  v_a_row jsonb;
  v_b_row jsonb;
begin
  if has_table_privilege('authenticated','public.sorting_daily_staff_modes','SELECT') then
    raise exception 'sorting_daily_staff_modes must remain private.';
  end if;

  v_result := public.set_sorting_staff_work_mode(
    v_shift,
    v_a,
    'MOP',
    'Snapshot 68 validation: A changed to MOP.'
  );

  if coalesce(v_result->>'audit_recorded','false')::boolean is not true then
    raise exception 'MOP change did not report audit evidence.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift);

  if coalesce(v_context->>'actual_mop_coverage','') <> 'DEDICATED'
     or coalesce(v_context->>'mop_staff_id','') <> v_a::text then
    raise exception 'A was not the single Actual MOP after assignment: %',v_context;
  end if;

  v_result := public.set_sorting_staff_work_mode(
    v_shift,
    v_a,
    'CLOTHES',
    'Snapshot 68 validation: A changed from MOP to Clothes.'
  );

  v_context := public.get_sorting_staff_work_context_v2(v_shift);

  select value into v_a_row
  from jsonb_array_elements(coalesce(v_context->'staff','[]'::jsonb))
  where value->>'staff_id'=v_a::text
  limit 1;

  if coalesce(v_a_row->>'work_mode','') <> 'CLOTHES'
     or nullif(v_a_row->>'work_mode_change_reason','') is null
     or coalesce(v_context->>'actual_mop_coverage','') <> 'NO_DEDICATED_MOP' then
    raise exception 'MOP -> Clothes change was not preserved as explicit Actual state: %, %',v_a_row,v_context;
  end if;

  v_result := public.set_sorting_staff_work_mode(
    v_shift,
    v_b,
    'MOP',
    'Snapshot 68 validation: B is the new MOP.'
  );

  v_context := public.get_sorting_staff_work_context_v2(v_shift);

  select value into v_a_row
  from jsonb_array_elements(coalesce(v_context->'staff','[]'::jsonb))
  where value->>'staff_id'=v_a::text
  limit 1;

  select value into v_b_row
  from jsonb_array_elements(coalesce(v_context->'staff','[]'::jsonb))
  where value->>'staff_id'=v_b::text
  limit 1;

  if coalesce(v_context->>'actual_mop_coverage','') <> 'DEDICATED'
     or coalesce(v_context->>'mop_staff_id','') <> v_b::text
     or coalesce(v_a_row->>'work_mode','') <> 'CLOTHES'
     or coalesce(v_b_row->>'work_mode','') <> 'MOP' then
    raise exception 'New MOP assignment did not leave exactly one MOP: %',v_context;
  end if;
end;
$$;

reset role;

do $$
declare
  v_a uuid := current_setting('eliscaretex.validation.a')::uuid;
  v_b uuid := current_setting('eliscaretex.validation.b')::uuid;
  v_count integer;
begin
  select count(*)
  into v_count
  from public.audit_log al
  where al.action='SORTING_WORK_MODE_CHANGED'
    and al.source_application='SORTING_V2'
    and al.actor_auth_user_id=current_setting('request.jwt.claim.sub')::uuid
    and al.reason like 'Snapshot 68 validation:%'
    and (
      al.new_data->>'staff_id'=v_a::text
      or al.new_data->>'staff_id'=v_b::text
    );

  if v_count < 3 then
    raise exception 'Expected at least three work-mode audit records, found %.',v_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608100006_sorting_staff_cards_time_and_work_mode_audit_validation',
  'mop_to_clothes_supported',true,
  'no_dedicated_actual_mop_supported',true,
  'single_actual_mop_enforced_on_reassignment',true,
  'work_mode_reason_exposed',true,
  'audit_log_recorded',true,
  'private_staff_mode_table_protected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
