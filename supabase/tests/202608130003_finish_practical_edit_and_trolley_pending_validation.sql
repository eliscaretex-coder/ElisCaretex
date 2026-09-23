-- ElisCaretex V2 — Validation 049
-- Structural validation only. Safe to run from SQL Editor without app auth.

do $$
declare
  v_def text;
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='finish_production_entries'
      and column_name='trolley_scan_status' and is_nullable='NO'
  ) then
    raise exception 'VALIDATION 049 FAIL: trolley_scan_status column is missing or nullable.';
  end if;

  if to_regprocedure('public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text)') is null then
    raise exception 'VALIDATION 049 FAIL: record_finish_production_v3 is missing.';
  end if;
  if to_regprocedure('public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text)') is null then
    raise exception 'VALIDATION 049 FAIL: correct_finish_production_v3 is missing.';
  end if;
  if to_regprocedure('public.get_finish_production_context_v3(text,timestamp with time zone)') is null then
    raise exception 'VALIDATION 049 FAIL: get_finish_production_context_v3 is missing.';
  end if;
  if to_regprocedure('public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamp with time zone)') is null then
    raise exception 'VALIDATION 049 FAIL: trolley scan status resolver is missing.';
  end if;

  select pg_get_functiondef('public.correct_finish_production(uuid,jsonb,text[],text,text)'::regprocedure)
  into v_def;
  if position('Correction reason is required.' in v_def)>0 then
    raise exception 'VALIDATION 049 FAIL: typed correction reason is still mandatory.';
  end if;

  if not exists(
    select 1 from pg_constraint c
    join pg_class t on t.oid=c.conrelid
    join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='public' and t.relname='finish_production_entries'
      and c.conname='finish_production_entries_trolley_scan_status_check'
  ) then
    raise exception 'VALIDATION 049 FAIL: trolley scan status check constraint is missing.';
  end if;

  raise notice 'VALIDATION 049 PASS';
end;
$$;

select jsonb_build_object(
  'validation','049',
  'status','PASS',
  'trolley_scan_status_column',exists(select 1 from information_schema.columns where table_schema='public' and table_name='finish_production_entries' and column_name='trolley_scan_status'),
  'record_v3',to_regprocedure('public.record_finish_production_v3(uuid,text,text,uuid,jsonb,text[],boolean,boolean,text)') is not null,
  'correct_v3',to_regprocedure('public.correct_finish_production_v3(uuid,uuid,jsonb,text[],boolean,boolean,text)') is not null,
  'context_v3',to_regprocedure('public.get_finish_production_context_v3(text,timestamp with time zone)') is not null
) as validation_result;
