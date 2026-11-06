-- Validation for 202611060018_mop_large_trolley_counts_as_medium.sql (run after it).
-- Ends with an error that starts with "TESTE OK"; nothing is kept.
begin;
do $$
declare
  v_m_flow uuid;
  v_s_flow uuid;
  v_l text[];
  v_m text;
  v_r jsonb;
begin
  -- A MOP customer whose plan is exactly 1 x M, and one whose plan is only S.
  select f.production_flow_item_id into v_m_flow
  from public.production_flow_items f
  join public.customer_schedule_trolley_requirements r on r.owner_schedule_product_id=f.source_schedule_product_id and r.active
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where f.product_code='MOP'
  group by f.production_flow_item_id
  having bool_and(tt.trolley_type_code='MEDIUM') and sum(r.quantity)=1
  limit 1;

  select f.production_flow_item_id into v_s_flow
  from public.production_flow_items f
  join public.customer_schedule_trolley_requirements r on r.owner_schedule_product_id=f.source_schedule_product_id and r.active
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where f.product_code='MOP'
  group by f.production_flow_item_id
  having bool_and(tt.trolley_type_code='SMALL') and sum(r.quantity)=1
  limit 1;

  -- Free trolleys (no open customer stay, available).
  select array_agg(t.trolley_code) into v_l from (
    select t.trolley_code from public.trolleys t join public.trolley_types tt on tt.trolley_type_id=t.trolley_type_id
    where tt.trolley_type_code='LARGE' and t.active and t.deleted_at is null and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED')
      and not exists(select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and s.received_on is null)
    order by t.trolley_code limit 2) t;
  select t.trolley_code into v_m from public.trolleys t join public.trolley_types tt on tt.trolley_type_id=t.trolley_type_id
  where tt.trolley_type_code='MEDIUM' and t.active and t.deleted_at is null and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED')
    and not exists(select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and s.received_on is null)
  order by t.trolley_code limit 1;

  if v_m_flow is null or v_s_flow is null or coalesce(array_length(v_l,1),0)<2 or v_m is null then
    raise exception 'FALHOU 0: nao achei dados para o teste (cliente MOP 1xM / 1xS ou trolleys livres L e M).';
  end if;

  -- Paulo (Administrator)
  perform set_config('request.jwt.claims', json_build_object('sub','234cba76-e05a-41b5-8253-71494d770db2','role','authenticated')::text, true);
  execute 'set local role authenticated';

  -- 1. Plan 1 x M, scanned 1 x L: OK.
  v_r := public.validate_mop_trolley_selection(v_m_flow, array[v_l[1]]);
  if not (v_r->>'matches_plan')::boolean then raise exception 'FALHOU 1: L nao foi aceito como M: %', v_r->'plan_issues'; end if;

  -- 2. Plan 1 x M, scanned 1 x M: still OK.
  v_r := public.validate_mop_trolley_selection(v_m_flow, array[v_m]);
  if not (v_r->>'matches_plan')::boolean then raise exception 'FALHOU 2: M deixou de ser aceito: %', v_r->'plan_issues'; end if;

  -- 3. Plan 1 x M, scanned 2 x L: quantity is still checked.
  v_r := public.validate_mop_trolley_selection(v_m_flow, v_l);
  if (v_r->>'matches_plan')::boolean then raise exception 'FALHOU 3: aceitou 2 trolleys para 1 planejado'; end if;

  -- 4. Plan 1 x S, scanned 1 x L: L does not replace S.
  v_r := public.validate_mop_trolley_selection(v_s_flow, array[v_l[1]]);
  if (v_r->>'matches_plan')::boolean then raise exception 'FALHOU 4: aceitou L no lugar de S'; end if;

  -- 5. Grants unchanged.
  execute 'reset role';
  if has_function_privilege('anon','public.validate_mop_trolley_selection(uuid,text[])','EXECUTE')
     or not has_function_privilege('authenticated','public.validate_mop_trolley_selection(uuid,text[])','EXECUTE') then
    raise exception 'FALHOU 5: permissoes da funcao mudaram';
  end if;

  raise exception 'TESTE OK - nada foi gravado (L aceito como M; M continua OK; quantidade e S continuam exatos).';
end;
$$;
rollback;
