-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080008_sorting_v2_trolley_suggestion_contract_fix
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_validation.customer_id',
  (
    select c.customer_id::text
    from public.customers c
    where c.active = true
      and c.deleted_at is null
    order by c.created_at, c.customer_name
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex_validation.trolley_type_id',
  (
    select tt.trolley_type_id::text
    from public.trolley_types tt
    where tt.active = true
      and tt.deleted_at is null
    order by tt.sort_order, tt.trolley_type_code
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex_validation.trolley_code',
  'TSORT' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)) || 'T',
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.customer_id', true), '') is null then
    raise exception 'No active customer was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.trolley_type_id', true), '') is null then
    raise exception 'No active trolley type was found.';
  end if;
end;
$$;

set local role authenticated;

select public.register_physical_trolley(
  p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
  p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
  p_registered_on => current_date,
  p_notes => 'Temporary Sorting V2 suggestion-contract validation trolley.',
  p_source_application => 'DATABASE_TEST'
);

do $$
declare
  v_raw record;
  v_record jsonb;
  v_preview jsonb;
  v_result jsonb;
  v_duplicate_rejected boolean := false;
begin
  select *
  into v_raw
  from public.suggest_trolley_customer(
    current_setting('eliscaretex_validation.trolley_code')
  );

  if v_raw.open_stay_id is not null
     or v_raw.suggested_customer_id is not null
     or coalesce(v_raw.suggestion_reason, '') <> 'NO_HISTORY' then
    raise exception 'Fresh validation trolley did not return the expected NO_HISTORY suggestion contract.';
  end if;

  v_record := public.get_trolley_record(
    current_setting('eliscaretex_validation.trolley_code')
  );

  if not ((v_record -> 'suggestion') ? 'open_stay_id')
     or not ((v_record -> 'suggestion') ? 'suggested_customer_id')
     or not ((v_record -> 'suggestion') ? 'suggested_customer_name')
     or not ((v_record -> 'suggestion') ? 'suggestion_reason') then
    raise exception 'get_trolley_record suggestion JSON does not expose the authoritative suggestion keys.';
  end if;

  v_preview := public.get_sorting_trolley_intake_preview(
    current_setting('eliscaretex_validation.trolley_code')
  );

  if coalesce(v_preview ->> 'suggestion_reason', '') <> 'NO_HISTORY'
     or nullif(v_preview ->> 'recommended_customer_id', '') is not null
     or coalesce(v_preview ->> 'confirmation_source', '') <> 'MANUAL_SELECTION'
     or coalesce((v_preview ->> 'needs_review_if_confirmed')::boolean, false) is not true then
    raise exception 'Sorting preview did not normalize the NO_HISTORY suggestion correctly: %', v_preview;
  end if;

  v_result := public.record_sorting_trolley_intake(
    current_setting('eliscaretex_validation.trolley_code'),
    current_setting('eliscaretex_validation.customer_id')::uuid,
    'Temporary Sorting V2 contract validation.'
  );

  if coalesce(v_result ->> 'exception_type', '') <> 'MISSING_OUTBOUND_RECORD'
     or coalesce(v_result ->> 'review_status', '') <> 'PENDING'
     or coalesce(v_result ->> 'confirmation_source', '') <> 'MANUAL_SELECTION' then
    raise exception 'Sorting intake did not preserve missing-outbound review behavior: %', v_result;
  end if;

  begin
    perform public.record_sorting_trolley_intake(
      current_setting('eliscaretex_validation.trolley_code'),
      current_setting('eliscaretex_validation.customer_id')::uuid,
      'Immediate duplicate validation.'
    );
  exception
    when unique_violation then
      v_duplicate_rejected := position('already recorded at Sorting' in sqlerrm) > 0;
  end;

  if not v_duplicate_rejected then
    raise exception 'Immediate duplicate Sorting intake was not rejected.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_event_count integer;
begin
  select count(*)
  into v_event_count
  from public.trolley_events te
  join public.trolleys t
    on t.trolley_id = te.trolley_id
  where t.trolley_code = current_setting('eliscaretex_validation.trolley_code')
    and te.business_date = current_date
    and te.event_type = 'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND';

  if v_event_count <> 1 then
    raise exception 'Expected exactly one missing-outbound Sorting event, found %.', v_event_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080008_sorting_v2_trolley_suggestion_contract_fix_validation',
  'raw_contract_open_stay_id', true,
  'raw_contract_suggested_customer_id', true,
  'raw_contract_suggestion_reason', true,
  'preview_contract_normalized', true,
  'missing_outbound_review_preserved', true,
  'duplicate_intake_rejected', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
