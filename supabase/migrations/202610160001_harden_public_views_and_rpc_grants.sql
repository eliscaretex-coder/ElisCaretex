-- Prevent public API roles from inheriting the view owner's privileges.
alter view public.v_active_customers set (security_invoker = true);
alter view public.v_customer_management set (security_invoker = true);
alter view public.v_customer_distribution_management set (security_invoker = true);
alter view public.v_customer_schedule_history set (security_invoker = true);
alter view public.v_distribution_current_schedule set (security_invoker = true);
alter view public.v_finish_current_schedule set (security_invoker = true);
alter view public.v_mop_current_schedule set (security_invoker = true);

revoke all on table public.v_active_customers from anon;
revoke all on table public.v_customer_management from anon;
revoke all on table public.v_customer_distribution_management from anon;
revoke all on table public.v_customer_schedule_history from anon;
revoke all on table public.v_distribution_current_schedule from anon;
revoke all on table public.v_finish_current_schedule from anon;
revoke all on table public.v_mop_current_schedule from anon;

-- These RPCs are internal or require a signed-in operator. Token-based roster
-- portal RPCs intentionally retain anon access for their public links.
revoke execute on function public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text) from anon;
revoke execute on function public.current_business_date() from anon;
revoke execute on function public.current_staff_id() from anon;
revoke execute on function public.deactivate_customer(uuid,text,text) from anon;
revoke execute on function public.get_distribution_roster_context(date) from anon;
revoke execute on function public.has_any_role(text[]) from anon;
revoke execute on function public.prevent_duplicate_sorting_trolley_intake_4h() from anon;
revoke execute on function public.publish_distribution_roster(date,text) from anon;
revoke execute on function public.reactivate_customer(uuid,text[],text,text) from anon;
revoke execute on function public.save_distribution_roster_draft(date,jsonb,text,text) from anon;
revoke execute on function public.sorting_schedule_product_snapshot(uuid,text,date) from anon;
revoke execute on function public.sorting_schedule_relation_for_date(date,date,boolean) from anon;
revoke execute on function public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text) from anon;

-- Avoid recalculating auth.uid() for every row covered by this policy.
drop policy if exists "staff_read_own_profile_or_management" on public.staff_members;
create policy "staff_read_own_profile_or_management"
on public.staff_members
for select
to authenticated
using (
  auth_user_id = (select auth.uid())
  or (select public.has_any_role(
    array['ADMIN', 'MANAGER', 'SUPERVISOR', 'ROSTER_MANAGER', 'AUDITOR']
  ))
);
