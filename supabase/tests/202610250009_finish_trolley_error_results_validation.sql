-- ElisCaretex V2 - Validation - Finish Results trolley errors
-- Read-only: runs as the FINISH-T1-PC01 station account inside a transaction and rolls back.
-- Run AFTER 202610250009_finish_trolley_error_results.sql is applied.

begin;

select set_config('request.jwt.claims', json_build_object('sub','b2aef431-0a4c-4c52-aef0-b64cbdf7a5fe','role','authenticated')::text, true);
set local role authenticated;

do $$
declare
  r jsonb;
  v_checked int;
  v_by_staff int;
  v_by_table int;
  v_by_shift int;
begin
  r := public.get_finish_trolley_errors_v1('2026-09-26','2026-10-25');
  if r->>'schema_version'<>'FINISH_TROLLEY_ERRORS_V1' then raise exception 'unexpected schema %', r->>'schema_version'; end if;
  v_checked := (r#>>'{total,checked_count}')::int;
  select coalesce(sum((x->>'checked_count')::int),0) into v_by_staff from jsonb_array_elements(r->'by_staff') x;
  select coalesce(sum((x->>'checked_count')::int),0) into v_by_table from jsonb_array_elements(r->'by_table') x;
  select coalesce(sum((x->>'checked_count')::int),0) into v_by_shift from jsonb_array_elements(r->'by_shift') x;
  if v_by_staff<>v_checked or v_by_table<>v_checked or v_by_shift<>v_checked then
    raise exception 'group totals differ: total % staff % table % shift %', v_checked, v_by_staff, v_by_table, v_by_shift;
  end if;
  if (r#>>'{total,error_count}')::int + (r#>>'{total,plan_reported_count}')::int <> jsonb_array_length(r->'entries') then
    raise exception 'entries list does not match error + plan reported counts: %', r->'total';
  end if;

  -- One date only when p_date_from is omitted.
  r := public.get_finish_trolley_errors_v1(null,'2026-10-25');
  if r->>'date_from'<>'2026-10-25' then raise exception 'expected single day, got %', r->>'date_from'; end if;

  begin
    perform public.get_finish_trolley_errors_v1('2026-10-25','2026-10-01');
    raise exception 'reversed range should fail';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.get_finish_trolley_errors_v1('2026-01-01','2026-10-25');
    raise exception 'range over 93 days should fail';
  exception when sqlstate '22023' then null;
  end;
end;
$$;

reset role;

do $$
begin
  if has_function_privilege('anon','public.get_finish_trolley_errors_v1(date,date)','EXECUTE') then raise exception 'anon must not execute trolley errors'; end if;
  if pg_get_functiondef('public.get_finish_trolley_errors_v1(date,date)'::regprocedure) not like '%require_finish_production_access%' then raise exception 'permission check missing'; end if;
end;
$$;

select 'Finish trolley errors validation passed' as result;
rollback;
