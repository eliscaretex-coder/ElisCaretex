-- Validation for 202611060017_legacy_sync_keep_trolley_units.sql (run after it).
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change (test revisions), so nothing is kept.
do $$
declare
  v_customer uuid := (select customer_id from public.customers where customer_name = 'HIGHFIELD');
  v_current uuid;
  v_source uuid;
  v_new uuid;
  v_have jsonb;
  v_n integer;
  v_sig_source text;
  v_sig text;
begin

  v_current := (integration.legacy_sync_schedule_versions(v_customer)->>'current')::uuid;
  select v.schedule_version_id into v_source from public.customer_schedule_versions v
  where v.customer_id = v_customer and v.change_reason = 'added the units of this customer';

  select string_agg(format('%s/%s/%s/%s=%s', d.production_weekday, pt.product_code, tt.trolley_type_code, pl.plate_number,
           (select string_agg(su.subunit_name, '+' order by s.o) from unnest(pl.subunit_ids) with ordinality s(id, o)
            join public.customer_subunits su on su.subunit_id = s.id)), ';'
           order by d.production_weekday, pt.product_code, tt.trolley_type_code, pl.plate_number)
  into v_sig_source
  from public.customer_schedule_days d
  join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
  join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
  join public.product_types pt on pt.product_type_id = p.product_type_id
  join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id
  join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
  where d.schedule_version_id = v_source;

  -- 1. HIGHFIELD: the current revision is the restore and has the 55 units of 30/10.
  select string_agg(format('%s/%s/%s/%s=%s', d.production_weekday, pt.product_code, tt.trolley_type_code, pl.plate_number,
           (select string_agg(su.subunit_name, '+' order by s.o) from unnest(pl.subunit_ids) with ordinality s(id, o)
            join public.customer_subunits su on su.subunit_id = s.id)), ';'
           order by d.production_weekday, pt.product_code, tt.trolley_type_code, pl.plate_number), count(*)
  into v_sig, v_n
  from public.customer_schedule_days d
  join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
  join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
  join public.product_types pt on pt.product_type_id = p.product_type_id
  join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id
  join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
  where d.schedule_version_id = v_current;
  if v_n <> 55 or v_sig is distinct from v_sig_source then
    raise exception 'FAILED 1: current revision has % plates, same as 30/10: %', v_n, v_sig = v_sig_source;
  end if;
  if not exists (select 1 from public.customer_schedule_versions where schedule_version_id = v_current
                 and status = 'PUBLISHED' and change_reason like 'Units restored:%') then
    raise exception 'FAILED 1b: the current revision is not the restore revision';
  end if;

  -- 2. ADARE keeps its revision with 6 units (nothing to restore).
  if (select count(*) from public.customer_schedule_versions v join public.customers c using (customer_id)
      where c.customer_name = 'ADARE' and v.change_reason like 'Units restored:%') <> 0 then
    raise exception 'FAILED 2: ADARE got a restore revision';
  end if;

  -- 3. A legacy change that does not touch trolleys keeps every unit.
  v_have := integration.legacy_sync_schedule_have(v_current) || '{"4.CLOTHES.order": 71}'::jsonb;
  v_new := integration.legacy_sync_schedule_publish(v_customer, v_current, array['4.CLOTHES.order'], v_have, 'validation 3');
  select count(*) into v_n from public.customer_schedule_days d
  join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
  join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
  where d.schedule_version_id = v_new;
  if v_n <> 55 then raise exception 'FAILED 3: % plates after a legacy order change', v_n; end if;

  -- 4. The legacy trolley text of Monday is rebuilt unchanged: every unit stays.
  v_current := v_new;
  v_have := integration.legacy_sync_schedule_have(v_current);
  v_new := integration.legacy_sync_schedule_publish(v_customer, v_current, array['1.trolleys'], v_have, 'validation 4');
  select count(*) into v_n from public.customer_schedule_days d
  join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
  join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
  where d.schedule_version_id = v_new;
  if v_n <> 55 then raise exception 'FAILED 4: % plates after Monday trolleys were rebuilt', v_n; end if;

  -- 5. Monday CLOTHES MEDIUM goes from 4 to 3 trolleys: plates 1-3 stay, plate 4 goes.
  v_current := v_new;
  v_have := integration.legacy_sync_schedule_have(v_current)
            || '{"1.trolleys": ["CLOTHES:MEDIUM:3", "CLOTHES:SMALL:4", "MOP:MEDIUM:3"]}'::jsonb;
  v_new := integration.legacy_sync_schedule_publish(v_customer, v_current, array['1.trolleys'], v_have, 'validation 5');
  select string_agg(pl.plate_number || '=' || (select string_agg(su.subunit_name, '+' order by s.o)
           from unnest(pl.subunit_ids) with ordinality s(id, o) join public.customer_subunits su on su.subunit_id = s.id),
           ';' order by pl.plate_number)
  into v_sig
  from public.customer_schedule_days d
  join public.customer_schedule_trolley_requirements r on r.schedule_day_id = d.schedule_day_id
  join public.customer_schedule_products p on p.schedule_product_id = r.owner_schedule_product_id
  join public.product_types pt on pt.product_type_id = p.product_type_id and pt.product_code = 'CLOTHES'
  join public.trolley_types tt on tt.trolley_type_id = r.trolley_type_id and tt.trolley_type_code = 'MEDIUM'
  join public.customer_schedule_trolley_plates pl on pl.schedule_trolley_requirement_id = r.schedule_trolley_requirement_id
  where d.schedule_version_id = v_new and d.production_weekday = 1;
  if v_sig is distinct from '1=DOMVILLE, STEELE;2=COGHILL, DANESWELL, FARNHAM;3=DRISHOGUE' then
    raise exception 'FAILED 5: Monday medium plates are %', v_sig;
  end if;

  -- 6. The functions stay internal.
  if has_function_privilege('authenticated', 'integration.legacy_sync_schedule_publish(uuid,uuid,text[],jsonb,text)', 'execute')
     or has_function_privilege('authenticated', 'integration.legacy_sync_schedule_write_draft(uuid,text[],jsonb)', 'execute') then
    raise exception 'FAILED 6: authenticated can call the legacy sync functions';
  end if;

  raise exception 'PASSED: units restored for HIGHFIELD (55), kept on legacy changes, trimmed to the trolley quantity.';
end;
$$;
