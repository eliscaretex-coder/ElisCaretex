-- PostgreSQL grants EXECUTE to PUBLIC by default. Revoke it at the inherited
-- role as well as anon, then explicitly retain signed-in application access.
revoke execute on function public.get_distribution_roster_context(date) from public, anon;
revoke execute on function public.prevent_duplicate_sorting_trolley_intake_4h() from public, anon;
revoke execute on function public.publish_distribution_roster(date,text) from public, anon;
revoke execute on function public.save_distribution_roster_draft(date,jsonb,text,text) from public, anon;
revoke execute on function public.sorting_schedule_product_snapshot(uuid,text,date) from public, anon;
revoke execute on function public.sorting_schedule_relation_for_date(date,date,boolean) from public, anon;

grant execute on function public.get_distribution_roster_context(date) to authenticated;
grant execute on function public.publish_distribution_roster(date,text) to authenticated;
grant execute on function public.save_distribution_roster_draft(date,jsonb,text,text) to authenticated;
grant execute on function public.sorting_schedule_product_snapshot(uuid,text,date) to authenticated;
grant execute on function public.sorting_schedule_relation_for_date(date,date,boolean) to authenticated;
