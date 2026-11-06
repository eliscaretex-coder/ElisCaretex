-- Validation for 202611050004_users_permissions_privacy_hardening.sql
-- Run manually against the development project after applying the migration.
begin;
select plan(16);

select is(public.mask_email('paulo.bressan@gmail.com'), 'pa***@g***.com', 'mask_email hides the address');
select ok(public.mask_emails_in_text('to anna@x.ie and bob.k@y.com') !~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'mask_emails_in_text hides every address');

select ok(not has_function_privilege('authenticated', 'public.finish_rewash_customer_options_v1(date)', 'execute'), 'customer list helper is internal');
select ok(not has_function_privilege('authenticated', 'public.sorting_schedule_product_snapshot(uuid,text,date)', 'execute'), 'schedule snapshot helper is internal');
select ok(not has_function_privilege('authenticated', 'public.issue_production_roster_gm_review_token(uuid)', 'execute'), 'GM review token is not issued to signed-in users');
select ok(has_function_privilege('service_role', 'public.issue_production_roster_gm_review_token(uuid)', 'execute'), 'GM review token is issued to the email service');
select ok(not has_function_privilege('anon', 'public.mask_email(text)', 'execute'), 'anon cannot call mask_email');

select ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r','p','v','m')
    and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select')
      or has_table_privilege('anon', c.oid, 'truncate') or has_table_privilege('authenticated', c.oid, 'truncate'))
), 'no direct table access for anon or authenticated');

select ok(pg_get_functiondef('public.current_account_is_enabled()'::regprocedure) like '%banned_until%', 'disabled accounts lose access at once');
select ok(pg_get_functiondef('public.current_account_is_enabled()'::regprocedure) like '%else false%', 'accounts without a profile, staff link or terminal are not enabled');
select ok(pg_get_functiondef('public.get_admin_account_access_directory(text)'::regprocedure) like '%mask_email(u.email)%', 'account directory masks emails');
select ok(pg_get_functiondef('public.prepare_production_roster_gm_review(uuid)'::regprocedure) not like '%''review_token'', v_token%', 'prepare does not return the review token');
select ok(pg_get_functiondef('public.save_production_roster_leave_governance_settings(integer,text,integer)'::regprocedure) like '%Only an Administrator can change the General Manager email%', 'only administrators change the GM email');

-- Negative: an account created through public sign-up (no profile) is not enabled
select set_config('request.jwt.claims', json_build_object('sub', '11111111-2222-3333-4444-555555555555', 'role', 'authenticated')::text, true);
set local role authenticated;
select ok(not public.current_account_is_enabled(), 'a self-registered account is not enabled');
select throws_ok('select public.finish_rewash_customer_options_v1(current_date)', '42501', null, 'a self-registered account cannot read the customer list');
select throws_ok('select count(*) from public.staff_members', '42501', null, 'a self-registered account cannot read Staff Master directly');
reset role;

select * from finish();
rollback;
