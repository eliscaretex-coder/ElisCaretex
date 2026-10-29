-- Validation for 202610290001_customer_subunits_and_trolley_plates.
-- Uses the live BLOOMFIELD customer (2 M + 3 S trolleys a day) inside a transaction
-- and rolls everything back.
begin;
select plan(31);

-- 1. Objects and grants.
select has_table('public','customer_subunits','customer_subunits exists');
select has_table('public','customer_schedule_trolley_plates','customer_schedule_trolley_plates exists');
select has_function('public','get_customer_subunits',array['uuid'],'get_customer_subunits exists');
select has_function('public','save_customer_subunits',array['uuid','jsonb','text','text'],'save_customer_subunits exists');
select has_function('public','get_production_flow_trolley_plates',array['uuid'],'get_production_flow_trolley_plates exists');
select ok(not has_function_privilege('anon','public.save_customer_subunits(uuid,jsonb,text,text)','execute'),'anon cannot save subunits');
select ok(not has_function_privilege('anon','public.get_production_flow_trolley_plates(uuid)','execute'),'anon cannot read trolley plates');
select ok(not has_function_privilege('authenticated','public.customer_schedule_trolley_plates_json(uuid)','execute'),'the internal plate builder is not callable');
select ok(not has_table_privilege('authenticated','public.customer_schedule_trolley_plates','select'),'plates are read only through RPCs');

-- 2. Customer Master subunits, as an account that can edit Customers.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'CUSTOMERS' and g.active and g.can_edit limit 1),'role','authenticated')::text, true);

create temporary table _c on commit drop as
select customer_id from public.customers where customer_name = 'BLOOMFIELD' and active and deleted_at is null limit 1;

select lives_ok($$select public.save_customer_subunits(customer_id,
  '[{"subunit_name":"D/BROOK"},{"subunit_name":"S/BROOK"},{"subunit_name":"KILAKEE"},{"subunit_name":"LAUREL"},{"subunit_name":"PERSON"},{"subunit_name":" OWENDOHER "}]'::jsonb,
  'Validation: Bloomfield subunits','VALIDATION') from _c$$,'six subunits are saved');
select is((select count(*)::integer from public.customer_subunits s join _c using (customer_id) where s.active),6,'six active subunits');
select is((select subunit_name from public.customer_subunits s join _c using (customer_id) where s.sort_order = 6),'OWENDOHER','names are trimmed and kept in order');
select throws_ok($$select public.save_customer_subunits(customer_id,'[{"subunit_name":"Laurel"},{"subunit_name":"LAUREL"}]'::jsonb,'Validation: duplicate','VALIDATION') from _c$$,'22023',null,'a duplicate name is refused');
select throws_ok($$select public.save_customer_subunits(customer_id,'[{"subunit_name":"LAUREL"}]'::jsonb,'','VALIDATION') from _c$$,'22023',null,'a reason is required');
select ok(exists(select 1 from public.audit_log l, _c where l.entity_id = _c.customer_id::text and l.action = 'SAVE_CUSTOMER_SUBUNITS'),'the subunit change is audited');
select ok((select jsonb_path_exists(public.get_customer_master_change_history(customer_id),'$.entries[*] ? (@.action == "SAVE_CUSTOMER_SUBUNITS").changes[*] ? (@.label == "Subunits" && @.after.size() == 6)') from _c),'the change history shows the subunits before and after');

create temporary table _su on commit drop as
select s.subunit_name, s.subunit_id from public.customer_subunits s join _c using (customer_id) where s.active;

-- Remove OWENDOHER and rename PERSON: the others keep their identity.
select lives_ok($$select public.save_customer_subunits(_c.customer_id, (
  select jsonb_agg(jsonb_build_object('subunit_id', subunit_id, 'subunit_name', case when subunit_name = 'PERSON' then 'PEARSON' else subunit_name end))
  from _su where subunit_name <> 'OWENDOHER'), 'Validation: remove and rename','VALIDATION') from _c$$,'a subunit is removed and one renamed');
select is((select active from public.customer_subunits where subunit_id = (select subunit_id from _su where subunit_name = 'OWENDOHER')),false,'the removed subunit is deactivated, not deleted');
select is((select subunit_name from public.customer_subunits where subunit_id = (select subunit_id from _su where subunit_name = 'PERSON')),'PEARSON','the renamed subunit keeps its id');

-- 3. Schedule draft with plates.
create temporary table _v on commit drop as
select public.create_customer_schedule_draft(customer_id, public.current_business_date() + 1, null, 'Validation: trolley plates','VALIDATION') as id from _c;

create temporary table _d on commit drop as
select jsonb_set(public.build_customer_schedule_version_snapshot(id), '{days,0,trolley_requirements,0,plates}', jsonb_build_array(
  jsonb_build_object('plate_number',1,'subunit_ids',jsonb_build_array((select subunit_id from _su where subunit_name = 'D/BROOK'))),
  jsonb_build_object('plate_number',2,'subunit_ids',jsonb_build_array((select subunit_id from _su where subunit_name = 'S/BROOK'),(select subunit_id from _su where subunit_name = 'KILAKEE')),'instructions','Validation: count per item')
)) as draft from _v;

select throws_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  jsonb_set(_d.draft,'{days,0,trolley_requirements,0,plates,0,plate_number}','9'),'Validation: plates','VALIDATION') from _v,_d$$,'22023',null,'a plate beyond the trolley quantity is refused');
select throws_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  jsonb_set(_d.draft,'{days,0,trolley_requirements,0,plates,0,subunit_ids}',jsonb_build_array(gen_random_uuid())),'Validation: plates','VALIDATION') from _v,_d$$,'22023',null,'a subunit of another customer is refused');
select throws_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  jsonb_set(_d.draft,'{days,0,trolley_requirements,0,plates,0,subunit_ids}',jsonb_build_array((select subunit_id from _su where subunit_name = 'OWENDOHER'))),'Validation: plates','VALIDATION') from _v,_d$$,'22023',null,'a removed subunit is refused');
select lives_ok($$select public.save_customer_schedule_draft(_v.id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),
  _d.draft,'Validation: plates','VALIDATION') from _v,_d$$,'the draft with two plates is saved');

create temporary table _snap on commit drop as select public.build_customer_schedule_version_snapshot(id) as s from _v;
select is((select jsonb_array_length(s->'days'->0->'trolley_requirements'->0->'plates') from _snap),2,'the snapshot lists the two plates');
select is((select s->'days'->0->'trolley_requirements'->0->'plates'->1->'subunit_names' from _snap),'["S/BROOK", "KILAKEE"]'::jsonb,'two subunits share plate 2, in order');
select ok((select jsonb_path_exists(public.build_customer_schedule_comparable_snapshot(id),'$.days[*].trolley_requirements[*].plates[*] ? (@.instructions == "Validation: count per item")') from _v),'a plate change is part of the comparable snapshot');

-- 4. Publish, then plates are locked and copied into the next draft.
select lives_ok($$select public.publish_customer_schedule_draft(id,(select row_version from public.customer_schedule_versions where schedule_version_id = _v.id),'Validation: publish plates','VALIDATION') from _v$$,'the draft with plates is published');
select throws_ok($$update public.customer_schedule_trolley_plates set instructions = 'changed' where schedule_trolley_requirement_id in (
  select r.schedule_trolley_requirement_id from public.customer_schedule_trolley_requirements r join public.customer_schedule_days d using (schedule_day_id) join _v on d.schedule_version_id = _v.id)$$,
  'P0001',null,'published plates cannot be changed');

create temporary table _v2 on commit drop as
select public.create_customer_schedule_draft(customer_id, public.current_business_date() + 2, null, 'Validation: copy plates','VALIDATION') as id from _c;
select is((select count(*)::integer from public.customer_schedule_trolley_plates p join public.customer_schedule_trolley_requirements r using (schedule_trolley_requirement_id)
  join public.customer_schedule_days d using (schedule_day_id) join _v2 on d.schedule_version_id = _v2.id),2,'a new draft copies the plates');

-- 5. Finish: one row per planned trolley of a production item.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  where g.module_code = 'FINISH' and g.active and g.can_edit limit 1),'role','authenticated')::text, true);
create temporary table _f on commit drop as
select public.get_production_flow_trolley_plates((
  select p.production_flow_item_id from public.production_flow_items p join _c using (customer_id)
  where p.product_code = 'CLOTHES' and p.source_schedule_product_id is not null
    and exists (select 1 from public.customer_schedule_trolley_requirements r where r.owner_schedule_product_id = p.source_schedule_product_id and r.active)
  order by p.scheduled_for_date desc limit 1)) as f;
select ok((select (f->>'trolley_count')::integer > 0 and (f->>'trolley_count')::integer = jsonb_array_length(f->'trolleys') from _f),'Finish sees one row per planned trolley');

-- 6. An account without Customers, Finish or MOP is refused.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CLEANER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_customer_subunits(customer_id) from _c$$,'42501',null,'Cleaner cannot read subunits');

select * from finish();
rollback;
