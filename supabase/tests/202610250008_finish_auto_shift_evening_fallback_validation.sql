-- ElisCaretex V2 - Validation - Finish Auto Shift Evening fallback
-- Read-only: runs as the FINISH-T1-PC01 station account inside a transaction and rolls back.
-- Run AFTER 202610250008_finish_auto_shift_evening_fallback.sql is applied.

begin;

select set_config('request.jwt.claims', json_build_object('sub','b2aef431-0a4c-4c52-aef0-b64cbdf7a5fe','role','authenticated')::text, true);
set local role authenticated;

do $$
declare
  r jsonb;
begin
  -- Sunday 2026-10-25: no EVENING work profile and Shift master start is empty.
  r := public.get_finish_auto_shift_context('2026-10-25 18:05+00');
  if r->>'recommended_shift_code'<>'EVENING' or r->>'reason'<>'EVENING_FALLBACK_START' then raise exception 'Sunday 18:05 expected EVENING fallback, got %', r; end if;
  r := public.get_finish_auto_shift_context('2026-10-25 10:00+00');
  if r->>'recommended_shift_code'<>'MORNING' then raise exception 'Sunday 10:00 expected MORNING, got %', r; end if;
  -- Monday still follows the Roster work profile (15:00).
  r := public.get_finish_auto_shift_context('2026-10-26 14:30+00');
  if r->>'recommended_shift_code'<>'MORNING' then raise exception 'Monday 14:30 expected MORNING, got %', r; end if;
  r := public.get_finish_auto_shift_context('2026-10-26 15:10+00');
  if r->>'reason'<>'EVENING_WORK_PROFILE_START' then raise exception 'Monday 15:10 expected work profile Evening, got %', r; end if;
  r := public.get_finish_auto_shift_context('2026-10-26 01:00+00');
  if r->>'reason'<>'EVENING_OVERNIGHT_CONTINUATION' then raise exception 'Monday 01:00 expected overnight continuation, got %', r; end if;
end;
$$;

reset role;

do $$
begin
  if has_function_privilege('anon','public.get_finish_auto_shift_context(timestamp with time zone)','EXECUTE') then raise exception 'anon must not execute Finish Auto Shift'; end if;
end;
$$;

select 'Finish Auto Shift Evening fallback validation passed' as result;
rollback;
