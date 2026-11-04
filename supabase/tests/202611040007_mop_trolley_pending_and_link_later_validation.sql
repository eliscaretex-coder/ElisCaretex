-- Validation for 202611040007_mop_trolley_pending_and_link_later.sql (pgTAP, no data written).
-- The end-to-end check (save with No trolley yet, then link the trolleys one by one)
-- is in the owner's "teste-sem-gravar.sql" for this change.
begin;
select plan(10);

select has_function('public','save_sorting_mop_production_v3',
  array['text','uuid','uuid','jsonb','text[]','boolean','date','time without time zone','text','text','boolean','boolean'],'save v3 exists');
select has_function('public','link_sorting_mop_production_trolleys',array['uuid','text[]'],'link rpc exists');

select ok(not has_function_privilege('anon','public.save_sorting_mop_production_v3(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean,boolean)','execute'),'anon cannot save');
select ok(not has_function_privilege('anon','public.link_sorting_mop_production_trolleys(uuid,text[])','execute'),'anon cannot link');
select ok(not has_function_privilege('authenticated','public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)','execute'),'inner save is not callable by users');

select ok(pg_get_functiondef('public.save_sorting_mop_production_v3(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean,boolean)'::regprocedure) like '%begin_mop_operational_scope%','save v3 checks MOP permission');
select ok(pg_get_functiondef('public.link_sorting_mop_production_trolleys(uuid,text[])'::regprocedure) like '%begin_mop_operational_scope%','link checks MOP permission');
select ok(pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)'::regprocedure) like '%eliscaretex.mop_trolley_pending%','inner save records PENDING when asked');
select ok(pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)'::regprocedure) like '%Scan the clean trolley used for this MOP customer before saving.%','inner save still refuses a live save without trolley');
select ok(pg_get_constraintdef((select oid from pg_constraint where conname='sorting_mop_production_trolley_status_check')) like '%PENDING%','status PENDING allowed');

select * from finish();
rollback;
