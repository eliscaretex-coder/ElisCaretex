-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080008_sorting_v2_trolley_suggestion_contract_fix.sql
-- Purpose:
--   Correct Sorting V2 trolley intake to use the authoritative output
--   contract of public.suggest_trolley_customer():
--     open_stay_id
--     suggested_customer_id
--     suggested_customer_name
--     suggestion_reason
--     last_sent_on
--     last_received_on
--
-- The original 202608080007 migration is intentionally not rewritten.
-- =====================================================================

begin;

create or replace function public.get_sorting_trolley_intake_preview(
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_trolley_code, '')));
  v_record jsonb;
  v_trolley jsonb;
  v_suggestion jsonb;
  v_current jsonb;
  v_status text;
  v_confirmation_source text;
  v_suggestion_reason text;
  v_suggested_customer_id uuid;
  v_suggested_customer_name text;
begin
  perform public.require_sorting_operational_access();

  if v_code = '' then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  v_record := public.get_trolley_record(v_code);
  v_trolley := coalesce(v_record -> 'trolley', '{}'::jsonb);
  v_suggestion := coalesce(v_record -> 'suggestion', '{}'::jsonb);
  v_current := v_record -> 'current_stay';
  v_status := upper(coalesce(v_trolley ->> 'status', ''));

  v_suggestion_reason := coalesce(v_suggestion ->> 'suggestion_reason', 'NO_HISTORY');
  v_suggested_customer_name := nullif(v_suggestion ->> 'suggested_customer_name', '');

  begin
    v_suggested_customer_id := nullif(v_suggestion ->> 'suggested_customer_id', '')::uuid;
  exception
    when invalid_text_representation then
      v_suggested_customer_id := null;
  end;

  v_confirmation_source := case
    when v_current is not null
         and jsonb_typeof(v_current) = 'object'
         and nullif(v_current ->> 'stay_id', '') is not null
      then 'OPEN_STAY'
    when v_suggestion_reason = 'LAST_KNOWN_CUSTOMER'
         and v_suggested_customer_id is not null
      then 'LAST_KNOWN_CUSTOMER'
    else 'MANUAL_SELECTION'
  end;

  return jsonb_build_object(
    'trolley', jsonb_build_object(
      'trolley_id', v_trolley ->> 'trolley_id',
      'trolley_code', v_trolley ->> 'trolley_code',
      'status', v_trolley ->> 'status',
      'type_code', v_trolley ->> 'trolley_type_code',
      'type_name', v_trolley ->> 'trolley_type_name',
      'type_display_code', v_trolley ->> 'trolley_type_display_code'
    ),
    'suggestion', v_suggestion,
    'current_stay', v_current,
    'recommended_customer_id', v_suggested_customer_id,
    'recommended_customer_name', v_suggested_customer_name,
    'suggestion_reason', v_suggestion_reason,
    'confirmation_source', v_confirmation_source,
    'needs_review_if_confirmed',
      not (
        v_current is not null
        and jsonb_typeof(v_current) = 'object'
        and nullif(v_current ->> 'stay_id', '') is not null
      ),
    'blocked', v_status in ('OUT_OF_SERVICE', 'RETIRED'),
    'message', case
      when v_status = 'OUT_OF_SERVICE'
        then 'This trolley is out of service and cannot be received in Sorting.'
      when v_status = 'RETIRED'
        then 'This trolley is retired and cannot be received in Sorting.'
      when v_current is not null
           and jsonb_typeof(v_current) = 'object'
           and nullif(v_current ->> 'stay_id', '') is not null
        then 'Open customer custody found. Confirm the customer before recording the Sorting arrival.'
      when v_suggested_customer_id is not null
        then 'No open outbound stay was found. The last known customer is suggested; confirmation will create a review item.'
      else
        'No customer history was found. Select the confirmed customer; the arrival will be recorded for review without inventing an outbound date.'
    end
  );
end;
$$;

create or replace function public.record_sorting_trolley_intake(
  p_trolley_code text,
  p_customer_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_trolley_code, '')));
  v_trolley_id uuid;
  v_suggestion record;
  v_confirmation_source text := 'MANUAL_SELECTION';
  v_result jsonb;
  v_customer_name text;
begin
  perform public.require_sorting_operational_access();

  if v_code = '' then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Confirmed customer is required.';
  end if;

  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Sorting intake notes must be 1000 characters or fewer.';
  end if;

  select t.trolley_id
  into v_trolley_id
  from public.trolleys t
  where lower(t.trolley_code) = lower(v_code)
    and t.deleted_at is null;

  if v_trolley_id is null then
    raise exception using errcode = 'P0002', message = format('Trolley not found: %s', v_code);
  end if;

  if exists (
    select 1
    from public.trolley_events te
    where te.trolley_id = v_trolley_id
      and te.business_date = current_date
      and te.customer_id = p_customer_id
      and te.event_type in (
        'ARRIVED_AT_SORTING',
        'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
        'CUSTOMER_MISMATCH'
      )
      and te.created_at >= now() - interval '10 minutes'
  ) then
    raise exception using
      errcode = '23505',
      message = format('Trolley %s was already recorded at Sorting a few minutes ago.', v_code);
  end if;

  select *
  into v_suggestion
  from public.suggest_trolley_customer(v_code);

  if v_suggestion.open_stay_id is not null then
    v_confirmation_source := 'OPEN_STAY';
  elsif v_suggestion.suggested_customer_id = p_customer_id
        and coalesce(v_suggestion.suggestion_reason, '') = 'LAST_KNOWN_CUSTOMER' then
    v_confirmation_source := 'LAST_KNOWN_CUSTOMER';
  else
    v_confirmation_source := 'MANUAL_SELECTION';
  end if;

  v_result := public.confirm_trolley_sorting_arrival(
    p_trolley_code => v_code,
    p_customer_id => p_customer_id,
    p_arrived_on => current_date,
    p_confirmation_source => v_confirmation_source,
    p_notes => nullif(trim(p_notes), '')
  );

  select c.customer_name
  into v_customer_name
  from public.customers c
  where c.customer_id = p_customer_id;

  return v_result || jsonb_build_object(
    'trolley_code', v_code,
    'customer_id', p_customer_id,
    'customer_name', v_customer_name,
    'confirmation_source', v_confirmation_source,
    'message', case
      when coalesce(v_result ->> 'review_status', '') = 'PENDING'
        then 'Trolley arrival recorded. A review item was created because the trolley history did not fully match the confirmed customer.'
      else 'Trolley arrival recorded successfully.'
    end
  );
end;
$$;

revoke all on function public.get_sorting_trolley_intake_preview(text)
  from public, anon, authenticated;
revoke all on function public.record_sorting_trolley_intake(text, uuid, text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_trolley_intake_preview(text)
  to authenticated;
grant execute on function public.record_sorting_trolley_intake(text, uuid, text)
  to authenticated;

comment on function public.get_sorting_trolley_intake_preview(text) is
  'Sorting trolley preview normalized from the authoritative suggest_trolley_customer output contract.';

comment on function public.record_sorting_trolley_intake(text, uuid, text) is
  'Current-day Sorting trolley intake using open_stay_id / suggested_customer_id / suggestion_reason from the authoritative trolley suggestion contract.';

commit;
