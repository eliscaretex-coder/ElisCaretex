-- Validation for 202610290005_production_tracker_finish_contributions.sql
-- Run against ElisCaretex-dev after the migration. Read-only; rolled back.
begin;
select plan(4);

select ok(not has_function_privilege('anon','public.get_production_tracker_v4(date)','execute'),'anon cannot call get_production_tracker_v4');
select ok(pg_get_functiondef('public.get_production_tracker_v4(date)'::regprocedure) like '%finish_entries%','V4 returns the Finish contributions');

select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'PRODUCTION_TRACKER' and g.active and g.can_view limit 1),'role','authenticated')::text, true);

create temporary table _t on commit drop as
select i.item from jsonb_array_elements(public.get_production_tracker_v4(public.current_business_date() - 1)->'items') i(item);

select is((select coalesce(sum(jsonb_array_length(item->'finish_entries')),0) from _t where item ? 'finish_entries')::integer,
          (select coalesce(sum((item->>'finish_contribution_count')::integer),0) from _t where item ? 'finish_contribution_count')::integer,
          'one Finish entry per contribution');
select is((select count(*) from _t, jsonb_array_elements(item->'finish_entries') x(e)
           where jsonb_array_length(x.e->'lines') = 0)::integer, 0, 'every contribution has its batch lines');

select * from finish();
rollback;
