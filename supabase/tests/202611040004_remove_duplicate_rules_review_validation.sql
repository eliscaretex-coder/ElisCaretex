-- Validation for 202611040004_remove_duplicate_rules_review.sql
-- Run against ElisCaretex-dev after the migration. Read-only; rolled back.
begin;
select plan(11);

-- 1. Duplicate indexes: the unused copy is gone, the copy in use stays.
select ok(to_regclass('public.distribution_roster_one_draft_per_week') is null, 'duplicate draft-per-week index dropped');
select ok(to_regclass('public.distribution_roster_one_published_per_week') is null, 'duplicate published-per-week index dropped');
select ok(to_regclass('public.distribution_roster_primary_driver_date_unique') is null, 'duplicate driver-per-day index dropped');
select ok((select indisunique from pg_index where indexrelid = 'public.distribution_roster_one_draft_per_week_idx'::regclass), 'one DRAFT roster per week is still enforced');
select ok((select indisunique from pg_index where indexrelid = 'public.distribution_roster_one_published_per_week_idx'::regclass), 'one PUBLISHED roster per week is still enforced');
select ok((select indisunique from pg_index where indexrelid = 'public.distribution_roster_entries_primary_driver_day_unique'::regclass), 'one roster line per driver per day is still enforced');

-- 2. MOP Type photo policies follow the MOP module permission.
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'mop_type_photos_manager_%'), 4, 'four MOP Type photo policies');
select ok(not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'mop_type_photos_manager_%'
  and coalesce(qual, '') || coalesce(with_check, '') like '%has_any_role%'), 'no MOP Type photo policy checks the legacy role alone');
select ok(not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'mop_type_photos_manager_%'
  and coalesce(qual, with_check) not like '%account_module_allowed%'), 'every MOP Type photo policy uses account_module_allowed');

-- The same rule as the MOP Type save: Production Manager (MOP: MANAGE) yes, Production Supervisor no.
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from public.account_access_profiles where job_title_code = 'PRODUCTION_MANAGER' and account_type = 'USER' limit 1), 'role', 'authenticated')::text, true);
select ok(public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']), 'Production Manager may manage MOP Type photos');
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from public.account_access_profiles where job_title_code = 'PRODUCTION_SUPERVISOR' and account_type = 'USER' limit 1), 'role', 'authenticated')::text, true);
select ok(not coalesce(public.account_module_allowed(array['MOP'], 'MANAGE', array['ADMIN', 'MANAGER']), false), 'Production Supervisor may not manage MOP Type photos');

select * from finish();
rollback;
