-- The Evening shift can close at 03:00. That exact boundary remains part of
-- the business date on which the shift began, not the following workday.

begin;

create or replace function public.operational_shift_clock_context(
  p_shift_code text,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_business_date date;
  v_overnight boolean := false;
begin
  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

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

  v_local := p_at at time zone v_timezone;
  v_business_date := v_local::date;
  if v_shift_code='EVENING' and v_local::time <= v_rollover then
    v_business_date := v_business_date - 1;
    v_overnight := true;
  end if;

  return jsonb_build_object(
    'shift_code',v_shift_code,
    'business_date',v_business_date,
    'calendar_date',v_local::date,
    'local_time',v_local::time,
    'timezone',v_timezone,
    'evening_rollover_time',v_rollover,
    'overnight_continuation',v_overnight
  );
end;
$$;

create or replace function public.operational_timestamp_for_shift(
  p_business_date date,
  p_shift_code text,
  p_local_time time
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_calendar_date date := p_business_date;
begin
  if p_business_date is null or p_local_time is null then
    return null;
  end if;
  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

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

  if v_shift_code='EVENING' and p_local_time <= v_rollover then
    v_calendar_date := p_business_date + 1;
  end if;

  return (
    (v_calendar_date::text || ' ' || p_local_time::text)::timestamp
    at time zone v_timezone
  );
end;
$$;

comment on function public.operational_timestamp_for_shift(date,text,time) is
  'Builds a Dublin timestamp for a Business Date; Evening local times through the configured rollover, including 03:00, are on the following calendar date.';

commit;
