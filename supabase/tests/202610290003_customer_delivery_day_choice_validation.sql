-- Validation for 202610290003_customer_delivery_day_choice.
-- Uses the live BLOOMFIELD customer inside a transaction and rolls everything back.
begin;
select plan(12);

-- 1. Nothing changes for the existing schedules and production items.
select is((
  select count(*)::integer
  from public.production_flow_items pfi
  where coalesce(pfi.scheduled_for_date, pfi.opened_business_date) >= public.current_business_date() - 60
    and public.schedule_delivery_date(pfi.source_schedule_day_id, coalesce(pfi.scheduled_for_date, pfi.opened_business_date))
        is distinct from public.next_distribution_business_date(coalesce(pfi.scheduled_for_date, pfi.opened_business_date))
), 0, 'every production item of the last 60 days keeps its delivery date');
select is(public.schedule_delivery_date(null, date '2026-10-31'), date '2026-11-02', 'without a schedule day Saturday still delivers on Monday');

-- 2. Production functions use the schedule delivery date.
select ok(pg_get_functiondef('public.get_finish_production_context(text,timestamptz)'::regprocedure) like '%schedule_delivery_date(p.source_schedule_day_id%', 'Finish queue uses the schedule delivery date');
select ok(pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)'::regprocedure) not like '%next_distribution_business_date%', 'MOP save no longer assumes the next day');
select ok(pg_get_functiondef('public.get_distribution_weekly_planner(date,smallint,text)'::regprocedure) like '%coalesce(d.delivery_weekday%', 'the Distribution planner reads the chosen delivery day');

-- 3. A draft keeps a later delivery day; the production day itself is refused.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'CUSTOMERS' and g.active and g.can_edit limit 1),'role','authenticated')::text, true);

create temporary table _c on commit drop as
select customer_id from public.customers where customer_name = 'BLOOMFIELD' and active and deleted_at is null limit 1;
create temporary table _v on commit drop as
select public.create_customer_schedule_draft(customer_id, public.current_business_date() + 1, null, 'Validation: delivery day','VALIDATION') as id from _c;
create temporary table _d on commit drop as
select public.build_customer_schedule_version_snapshot(id) as s from _v;

select throws_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  jsonb_set(_d.s,'{days,0,delivery_weekday}',to_jsonb((_d.s->'days'->0->>'production_weekday')::integer)),'Validation: delivery day','VALIDATION') from _v,_d$$,
  '22023',null,'delivery on the production weekday is refused');

-- Monday production delivered on Wednesday (two days later).
select lives_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  jsonb_set(_d.s,'{days,0,delivery_weekday}','3'),'Validation: delivery day','VALIDATION') from _v,_d$$,'a later delivery day is saved');

create temporary table _day on commit drop as
select d.schedule_day_id, d.production_weekday, d.delivery_weekday
from public.customer_schedule_days d join _v on d.schedule_version_id = _v.id
where d.active order by d.production_weekday limit 1;

select is((select delivery_weekday::integer from _day), 3, 'the chosen delivery weekday is stored, not overwritten');
select is((select public.schedule_delivery_date(schedule_day_id, date '2026-11-02') from _day), date '2026-11-04', 'Monday production is delivered on Wednesday');
select is((select build_customer_schedule_version_snapshot(id)->'days'->0->>'delivery_day' from _v), 'Wednesday', 'the schedule shows the chosen delivery day');

-- 4. After publishing, the customer's delivery date follows the new schedule.
select lives_ok($$select public.publish_customer_schedule_draft(id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),'Validation: publish delivery day','VALIDATION') from _v$$,'the schedule is published');
select is((select public.customer_delivery_date(customer_id, (public.current_business_date() + 1 + ((8 - extract(isodow from public.current_business_date() + 1)::integer) % 7))::date)
           - (public.current_business_date() + 1 + ((8 - extract(isodow from public.current_business_date() + 1)::integer) % 7))::date from _c),
          2, 'the next Monday production of the customer is delivered two days later');

select * from finish();
rollback;
