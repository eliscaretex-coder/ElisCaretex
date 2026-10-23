-- Validation for 202610230002_production_roster_exit_after_role_change.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(12);

select has_column('public','staff_members','production_roster_until','staff_members has production_roster_until');
select ok(public.job_title_keeps_production_roster('GENERAL_OPERATIVE'),'General Operative keeps the Production Roster');
select ok(public.job_title_keeps_production_roster('CLEANER'),'Cross-department Cleaner keeps the Production Roster');
select ok(public.job_title_keeps_production_roster(null),'staff without an account keep the Production Roster');
select ok(not public.job_title_keeps_production_roster('LOGISTICS_MANAGER'),'Logistics Manager leaves the Production Roster');
select ok(not has_function_privilege('authenticated','public.sync_staff_production_roster_exit(uuid,text)','execute'),'authenticated cannot call the internal sync');
select ok(not has_function_privilege('anon','public.sync_staff_production_roster_exit(uuid,text)','execute'),'anon cannot call the internal sync');
select ok(exists(select 1 from pg_trigger where tgname='account_job_title_production_roster_exit' and not tgisinternal),'job title trigger exists');
select ok(exists(select 1 from pg_trigger where tgname='staff_account_link_production_roster_exit' and not tgisinternal),'account link trigger exists');
select ok(pg_get_functiondef('public.production_roster_assert_operational_rules(uuid)'::regprocedure) like '%production_roster_until%','save/publish guard checks the exit date');

-- Every linked production staff member whose job title left Production has an exit date.
select ok(not exists(
  select 1 from public.staff_members sm
  join public.account_access_profiles ap on ap.auth_user_id = sm.auth_user_id and ap.account_type = 'USER'
  where sm.deleted_at is null and sm.production_staff
    and not public.job_title_keeps_production_roster(ap.job_title_code)
    and sm.production_roster_until is null
),'staff outside Production have an exit date');

-- No editable draft after an exit week still lists the staff member.
select ok(not exists(
  select 1 from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
  join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where prv.status = 'DRAFT' and sm.production_roster_until < rp.week_start
),'no draft after the exit week keeps the staff member');

select * from finish();
rollback;
