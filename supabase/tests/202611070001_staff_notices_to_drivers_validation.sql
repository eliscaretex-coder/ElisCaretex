-- Validation for 202611070001_staff_notices_to_drivers.sql (run after applying).
-- The full scenario test (Logistics Manager -> driver, Production Supervisor unchanged,
-- driver acknowledges, receipts) is in the owner's teste-sem-gravar.sql; it passed on
-- ElisCaretex-dev on 2026-11-07 inside a rolled-back transaction.
begin;
select plan(9);
select has_function('public','staff_notice_sender_scope',array[]::text[],'sender scope helper exists');
select has_function('public','staff_notice_eligible_recipients',array[]::text[],'eligible recipients helper exists');
select ok(not has_function_privilege('authenticated','public.staff_notice_eligible_recipients()','execute'),'browser cannot call eligible recipients helper');
select ok(not has_function_privilege('authenticated','public.staff_notice_sender_scope()','execute'),'browser cannot call sender scope helper');
select ok(not has_function_privilege('anon','public.send_staff_notice(text,text,text,boolean,uuid[],integer)','execute'),'anon cannot send notices');
select ok(not has_function_privilege('anon','public.get_notification_recipient_options()','execute'),'anon cannot list recipients');
select ok(pg_get_functiondef('public.send_staff_notice(text,text,text,boolean,uuid[],integer)'::regprocedure) like '%staff_notice_eligible_recipients%','send uses the eligible recipients helper');
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='DRIVER' and module_code='NOTIFICATIONS' and can_view and not can_create),'drivers read notifications');
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='LOGISTICS_MANAGER' and module_code='NOTIFICATIONS' and access_scope='DISTRIBUTION' and can_create),'Logistics Manager sends to Distribution');
select * from finish();
rollback;
