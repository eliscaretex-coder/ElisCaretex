-- ElisCaretex V2
-- Sorting trolley intake: allow one-day-late and published future schedule dates.

begin;

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_relation_check;

alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_relation_check
  check (schedule_relation in ('YESTERDAY','TODAY','TOMORROW','FUTURE','OFF_SCHEDULE'));

do $migration$
declare
  v_sql text;
begin
  select pg_get_functiondef('public.get_sorting_trolley_intake_context_v2(text)'::regprocedure)
  into v_sql;

  v_sql := regexp_replace(
    v_sql,
    'with board_days as \(\s+select v_business_date-1 as scheduled_for_date, ''YESTERDAY''::text as day_relation, -1 as day_offset\s+union all\s+select v_business_date, ''TODAY''::text, 0\s+union all\s+select v_business_date\+1, ''TOMORROW''::text, 1\s+\),',
    $new$with board_days as (
    select v_business_date-1 as scheduled_for_date, 'YESTERDAY'::text as day_relation, -1 as day_offset
    union all
    select v_business_date, 'TODAY'::text, 0
    union all
    select
      gs::date as scheduled_for_date,
      case when gs::date=v_business_date+1 then 'TOMORROW' else 'FUTURE' end::text as day_relation,
      (gs::date-v_business_date)::integer as day_offset
    from generate_series(v_business_date+1, v_business_date+7, interval '1 day') gs
  ),
$new$);

  v_sql := replace(
    v_sql,
    $$and row->>'day_relation' in ('TODAY','TOMORROW')$$,
    $$and row->>'day_relation' in ('TODAY','TOMORROW','FUTURE')$$
  );

  execute v_sql;

  select pg_get_functiondef('public.get_sorting_trolley_intake_context_v3(text)'::regprocedure)
  into v_sql;

  v_sql := replace(
    v_sql,
    $$case q.value->>'day_relation' when 'TODAY' then 0 when 'TOMORROW' then 1 else 2 end$$,
    $$case q.value->>'day_relation' when 'TODAY' then 0 when 'TOMORROW' then 1 when 'FUTURE' then 2 else 3 end$$
  );

  v_sql := replace(
    v_sql,
    $$and q.value->>'day_relation' in ('TODAY','TOMORROW')$$,
    $$and q.value->>'day_relation' in ('TODAY','TOMORROW','FUTURE')$$
  );

  execute v_sql;

  select pg_get_functiondef('public.record_sorting_trolley_intake_v2(text,text,uuid,uuid,text,date,text[],text,text,text)'::regprocedure)
  into v_sql;

  v_sql := regexp_replace(
    v_sql,
    'if p_scheduled_for_date < v_business_date-1\s+or p_scheduled_for_date > v_business_date\+1 then\s+raise exception using\s+errcode=''22023'',\s+message=''Scheduled Date must be Yesterday, Today or Tomorrow for Sorting Intake.'';\s+end if;\s+v_relation := case\s+when p_scheduled_for_date=v_business_date-1 then ''YESTERDAY''\s+when p_scheduled_for_date=v_business_date then ''TODAY''\s+else ''TOMORROW''\s+end;',
    $new$
    if p_scheduled_for_date < v_business_date-1 then
      raise exception using
        errcode='22023',
        message='Scheduled Date cannot be earlier than yesterday for Sorting Intake.';
    end if;

    if p_scheduled_for_date > v_business_date+7 then
      raise exception using
        errcode='22023',
        message='Scheduled Date must be within the next 7 scheduled days for Sorting Intake.';
    end if;

    v_relation := case
      when p_scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      when p_scheduled_for_date=v_business_date then 'TODAY'
      when p_scheduled_for_date=v_business_date+1 then 'TOMORROW'
      else 'FUTURE'
    end;
$new$);

  execute v_sql;
end $migration$;

commit;
