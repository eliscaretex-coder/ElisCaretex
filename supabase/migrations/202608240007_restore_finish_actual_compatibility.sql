-- Keep the live browser release working until its terminal-wrapper update is published.

grant execute on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) to authenticated;
