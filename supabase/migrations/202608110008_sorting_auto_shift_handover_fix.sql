-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110008_sorting_auto_shift_handover_fix
--
-- Fix:
--   The browser previously called get_sorting_auto_shift_context with
--   p_at = NULL. PostgreSQL defaults are not applied when NULL is supplied
--   explicitly, so the function could incorrectly recommend MORNING after
--   the Evening handover.
--
-- Safeguard:
--   Coalesce a NULL p_at to now() inside the authoritative function.
-- =====================================================================

begin;

create or replace function public.get_sorting_auto_shift_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_reference_at timestamptz := coalesce(p_at, now());
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_evening_profile jsonb;
  v_evening_start time := time '14:00';
  v_shift_code text;
  v_business_date date;
  v_reason text;
  v_next_change timestamp;
begin
  perform public.require_sorting_operational_access();

  select coalesce(nullif(value_json #>> '{}', ''), 'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key = 'business_timezone';

  v_timezone := coalesce(v_timezone, 'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}', '')::time, time '03:00')
  into v_rollover
  from public.app_config
  where config_key = 'evening_shift_rollover_time';

  v_rollover := coalesce(v_rollover, time '03:00');

  v_local := v_reference_at at time zone v_timezone;
  v_local_date := v_local::date;
  v_local_time := v_local::time;

  if v_local_time < v_rollover then
    v_shift_code := 'EVENING';
    v_business_date := v_local_date - 1;
    v_reason := 'EVENING_OVERNIGHT_CONTINUATION';
    v_next_change := (v_local_date::text || ' ' || v_rollover::text)::timestamp;
  else
    v_evening_profile := public.production_roster_work_profile_context(
      v_local_date,
      'EVENING'
    );

    if nullif(v_evening_profile ->> 'default_start_time', '') is not null then
      v_evening_start := (v_evening_profile ->> 'default_start_time')::time;
    end if;

    if v_local_time >= v_evening_start then
      v_shift_code := 'EVENING';
      v_business_date := v_local_date;
      v_reason := case
        when v_evening_profile is null then 'EVENING_FALLBACK_START'
        else 'EVENING_STANDARD_START'
      end;
      v_next_change := (
        (v_local_date + 1)::text || ' ' || v_rollover::text
      )::timestamp;
    else
      v_shift_code := 'MORNING';
      v_business_date := v_local_date;
      v_reason := case
        when v_evening_profile is null then 'BEFORE_EVENING_FALLBACK_START'
        else 'BEFORE_EVENING_STANDARD_START'
      end;
      v_next_change := (
        v_local_date::text || ' ' || v_evening_start::text
      )::timestamp;
    end if;
  end if;

  return jsonb_build_object(
    'recommended_shift_code', v_shift_code,
    'business_date', v_business_date,
    'local_date', v_local_date,
    'local_time', v_local_time,
    'timezone', v_timezone,
    'evening_rollover_time', v_rollover,
    'evening_standard_start', v_evening_start,
    'reason', v_reason,
    'next_auto_change_local', v_next_change,
    'reference_at', v_reference_at
  );
end;
$$;

revoke all on function public.get_sorting_auto_shift_context(timestamptz)
  from public, anon, authenticated;

grant execute on function public.get_sorting_auto_shift_context(timestamptz)
  to authenticated;

comment on function public.get_sorting_auto_shift_context(timestamptz) is
  'Authoritative Sorting Auto Shift context. NULL p_at is treated as now(), preventing a workstation from remaining on the previous shift after handover.';

commit;
