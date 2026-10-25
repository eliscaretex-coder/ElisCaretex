-- ElisCaretex V2 - Finish Auto Shift: Evening start fallback
-- PREPARED: owner executes in Development.
--
-- Problem:
-- - get_finish_auto_shift_context raised "Evening shift start time could not be resolved
--   from the Roster work profile or Shift master." on days without an EVENING Roster work
--   profile (Sunday has none) because shifts.start_time for EVENING is empty.
-- - get_sorting_auto_shift_context (also used by MOP) never fails here: it falls back to 14:00.
--
-- Change:
-- - Resolve the Evening start from the Roster work profile, then the Shift master,
--   then the same 14:00 fallback Sorting uses. The Finish screen no longer blocks.
-- - No data is changed. Return shape is unchanged; new reason codes
--   EVENING_FALLBACK_START / BEFORE_EVENING_FALLBACK_START mark the fallback path.

begin;

create or replace function public.get_finish_auto_shift_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_reference_at timestamptz := coalesce(p_at,now());
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_evening_profile jsonb;
  v_evening_start time;
  v_source text;
  v_shift_code text;
  v_business_date date;
  v_reason text;
  v_next_change timestamp;
begin
  perform public.require_finish_production_access();

  select coalesce(nullif(value_json #>> '{}',''),'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key='business_timezone';
  v_timezone := coalesce(v_timezone,'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}','')::time,time '03:00')
  into v_rollover
  from public.app_config
  where config_key='evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover,time '03:00');

  v_local := v_reference_at at time zone v_timezone;
  v_local_date := v_local::date;
  v_local_time := v_local::time;

  if v_local_time < v_rollover then
    v_shift_code := 'EVENING';
    v_business_date := v_local_date - 1;
    v_reason := 'EVENING_OVERNIGHT_CONTINUATION';
    v_next_change := (v_local_date::text || ' ' || v_rollover::text)::timestamp;
  else
    v_evening_profile := public.production_roster_work_profile_context(v_local_date,'EVENING');
    v_evening_start := nullif(v_evening_profile ->> 'default_start_time','')::time;
    v_source := 'WORK_PROFILE';

    if v_evening_start is null then
      select sh.start_time
      into v_evening_start
      from public.shifts sh
      where sh.shift_code='EVENING' and sh.active=true and sh.deleted_at is null
      limit 1;
      v_source := 'SHIFT_MASTER';
    end if;

    if v_evening_start is null then
      -- Same fallback as get_sorting_auto_shift_context.
      v_evening_start := time '14:00';
      v_source := 'FALLBACK';
    end if;

    if v_local_time >= v_evening_start then
      v_shift_code := 'EVENING';
      v_business_date := v_local_date;
      v_reason := 'EVENING_' || v_source || '_START';
      v_next_change := ((v_local_date + 1)::text || ' ' || v_rollover::text)::timestamp;
    else
      v_shift_code := 'MORNING';
      v_business_date := v_local_date;
      v_reason := 'BEFORE_EVENING_' || v_source || '_START';
      v_next_change := (v_local_date::text || ' ' || v_evening_start::text)::timestamp;
    end if;
  end if;

  return jsonb_build_object(
    'recommended_shift_code',v_shift_code,
    'business_date',v_business_date,
    'local_date',v_local_date,
    'local_time',v_local_time,
    'timezone',v_timezone,
    'evening_rollover_time',v_rollover,
    'evening_standard_start',v_evening_start,
    'evening_work_profile',v_evening_profile,
    'reason',v_reason,
    'next_auto_change_local',v_next_change,
    'reference_at',v_reference_at
  );
end;
$$;

revoke all on function public.get_finish_auto_shift_context(timestamptz) from public, anon;
grant execute on function public.get_finish_auto_shift_context(timestamptz) to authenticated;

commit;
