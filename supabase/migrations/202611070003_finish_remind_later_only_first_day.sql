-- Finish Production: "Not processed · remind in 2 hours" only up to 1 day late.
--
-- Problem: the "Finish confirmation required" dialog lets staff answer
-- "Not processed", which hides a late customer for two hours. Staff kept
-- postponing the same customers for days.
--
-- Rule (owner decision 2026-11-07): the two-hour reminder is allowed only while
-- the customer is at most 1 day late, measured like overdue_days in
-- get_finish_delivery_reconciliation_context (Dublin date minus Delivery Date).
-- From the second day after the Delivery Date the answer is refused: staff must
-- confirm the approximate processing, or an administrator clears the customer
-- with "Clean up list" (202611060016).
--
-- Both resolve RPCs (v1 is still callable) are patched from their live
-- definitions with an exact text insert that must match once, so the migration
-- fails instead of silently changing something else. Existing answers and
-- reminders are not touched.

do $patch$
declare
  v_fn regprocedure;
  v_definition text;
  v_anchor constant text := '  if coalesce(v_flow.washed_trace_count,0)<=0 then';
  v_guard constant text :=
'  if v_outcome=''NOT_PROCESSED'' and v_local_date-v_delivery_date>1 then
    raise exception using errcode=''22023'',message=''This customer is more than 1 day late. Remind in 2 hours is no longer available: confirm the approximate processing, or ask an administrator to clean up the list.'';
  end if;
';
  v_count integer;
begin
  foreach v_fn in array array[
    'public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text)'::regprocedure,
    'public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)'::regprocedure
  ] loop
    v_definition := pg_get_functiondef(v_fn);
    if position('v_local_date-v_delivery_date>1' in v_definition) > 0 then
      continue; -- already patched
    end if;
    v_count := (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
    if v_count <> 1 then
      raise exception 'Remind-later patch: % has % occurrence(s) of the anchor, expected 1.', v_fn, v_count;
    end if;
    execute replace(v_definition, v_anchor, v_guard || v_anchor);
  end loop;
end;
$patch$;

revoke all on function public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) from public, anon;
grant execute on function public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) to authenticated;
revoke all on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) from public, anon;
grant execute on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) to authenticated;
