-- Validation for 202611070003_finish_remind_later_only_first_day.sql.
-- Run in the SQL Editor after the migration. It ends with an error that starts with
-- "PASSED": the error rolls back every change (answers, audit rows), so nothing is kept.
do $$
declare
  v_admin uuid;
  v_late uuid;
  v_recent uuid;
  v_r jsonb;
  v_failed boolean;
  v_msg text;
begin
  -- 1. Both RPCs carry the guard and keep their grants.
  if pg_get_functiondef('public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text)'::regprocedure) not like '%v_local_date-v_delivery_date>1%'
     or pg_get_functiondef('public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)'::regprocedure) not like '%v_local_date-v_delivery_date>1%' then
    raise exception 'FAILED 1a: guard missing';
  end if;
  if has_function_privilege('anon','public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)','execute')
     or not has_function_privilege('authenticated','public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)','execute') then
    raise exception 'FAILED 1b: grants';
  end if;

  select auth_user_id into v_admin from public.account_access_profiles
  where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  if v_admin is null then raise exception 'FAILED 0: no ADMINISTRATOR account to test with'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- Washed Clothes customers with no Finish production, by how late they are.
  with c as (
    select f.production_flow_item_id id,
           public.schedule_delivery_date(f.source_schedule_day_id,f.scheduled_for_date) delivery_date
    from public.production_flow_items f
    where f.product_code='CLOTHES' and coalesce(f.washed_trace_count,0)>0
      and not exists (
        select 1 from public.finish_production_entries e
        join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
        where e.production_flow_item_id=f.production_flow_item_id and e.status='ACTIVE' and l.quantity>0)
  )
  select
    (select id from c where (now() at time zone 'Europe/Dublin')::date-delivery_date>1 limit 1),
    (select id from c where (now() at time zone 'Europe/Dublin')::date-delivery_date between 0 and 1
       and now()>=public.finish_delivery_cutoff(delivery_date) order by delivery_date limit 1)
  into v_late, v_recent;

  -- 2. More than 1 day late: "Not processed" is refused by v2 and by v1.
  if v_late is not null then
    v_failed := false;
    begin perform public.resolve_finish_delivery_reconciliation_v2(v_late,'NOT_PROCESSED',null,null,null,null,'validation');
    exception when invalid_parameter_value then v_failed := true; get stacked diagnostics v_msg = message_text; end;
    if not v_failed or v_msg not like '%more than 1 day late%' then raise exception 'FAILED 2a: v2 allowed remind later (%)', v_msg; end if;
    v_failed := false;
    begin perform public.resolve_finish_delivery_reconciliation_v1(v_late,'NOT_PROCESSED',null,null,null,'validation');
    exception when invalid_parameter_value then v_failed := true; end;
    if not v_failed then raise exception 'FAILED 2b: v1 allowed remind later'; end if;

    -- 3. ...but confirming the processing still works.
    v_r := public.resolve_finish_delivery_reconciliation_v2(v_late,'PROCESSED_CONFIRMED',current_date,10,'KG',null,'validation');
    if v_r->>'outcome_code' <> 'PROCESSED_CONFIRMED' then raise exception 'FAILED 3: %', v_r; end if;
  end if;

  -- 4. Up to 1 day late: "Not processed" still schedules the 2-hour reminder.
  if v_recent is not null then
    v_r := public.resolve_finish_delivery_reconciliation_v2(v_recent,'NOT_PROCESSED',null,null,null,null,'validation');
    if v_r->>'outcome_code' <> 'NOT_PROCESSED' or (v_r->>'next_prompt_at') is null then raise exception 'FAILED 4: %', v_r; end if;
  end if;

  raise exception 'PASSED: remind in 2 hours limited to 1 day late (late item %, recent item %)',
    coalesce(v_late::text,'none waiting'), coalesce(v_recent::text,'none waiting');
end;
$$;
