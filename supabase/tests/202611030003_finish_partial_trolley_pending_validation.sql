-- TESTE SEM GRAVAR - Finish: "No trolley yet" so para o trolley que falta
-- Cria a funcao nova so dentro deste bloco, testa como o computador FINISH-T1-PC01 e no
-- final FORCA um erro para desfazer tudo. Nada fica gravado.
-- Resultado esperado: um erro que comeca com "TESTE OK - nada foi gravado".
-- Qualquer outra mensagem quer dizer que uma verificacao falhou.

do $t$
declare
  v_flow uuid;
  v_type uuid;
  v_code text;
  v_planned int;
  r jsonb;
  v_err text;
begin
  execute $ddl$create or replace function public.finish_resolve_trolley_scan_status(
  p_production_flow_item_id uuid,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_pending boolean default false,
  p_accept_trolley_mismatch boolean default false,
  p_at timestamp with time zone default now()
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_check jsonb;
  v_codes text[];
  v_planned integer;
  v_scanned integer;
  v_status text;
begin
  perform public.require_finish_production_access();

  select coalesce(array_agg(distinct upper(trim(x)) order by upper(trim(x))),array[]::text[])
  into v_codes
  from unnest(coalesce(p_trolley_codes,array[]::text[])) x
  where nullif(trim(x),'') is not null;

  v_check:=public.validate_finish_trolley_selection(
    p_production_flow_item_id,v_codes,coalesce(p_at,now())
  );
  v_planned:=coalesce((v_check->>'planned_total')::integer,0);
  v_scanned:=coalesce((v_check->>'scanned_total')::integer,0);

  if coalesce((v_check->>'hard_block')::boolean,false) then
    raise exception using errcode='23514', message='One or more scanned trolleys cannot be used. Review the trolley scan.';
  end if;

  if coalesce(p_trolley_pending,false) then
    if v_planned=0 then
      v_status:='NOT_REQUIRED';
    elsif v_scanned>=v_planned and coalesce((v_check->>'matches_plan')::boolean,false) then
      -- Everything planned is already scanned: nothing is really pending.
      v_status:='MATCHED';
    else
      v_status:='PENDING';
    end if;
  elsif v_planned=0 and v_scanned=0 then
    v_status:='NOT_REQUIRED';
  elsif coalesce((v_check->>'matches_plan')::boolean,false) then
    v_status:='MATCHED';
  else
    if v_scanned=0 and v_planned>0 then
      raise exception using errcode='23514', message='No trolley has been scanned. Scan the trolley or choose No trolley yet.';
    end if;
    if not coalesce(p_accept_trolley_mismatch,false) then
      raise exception using errcode='23514', message='Trolley quantity/type does not match the published plan. Review the scan or explicitly accept the mismatch.';
    end if;
    v_status:='MISMATCH';
  end if;

  return jsonb_build_object(
    'status',v_status,
    'validation',v_check,
    'planned_total',v_planned,
    'scanned_total',v_scanned
  );
end;
$function$$ddl$;
  execute 'revoke all on function public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamp with time zone) from public, anon, authenticated';

  perform set_config('request.jwt.claims', json_build_object('sub','b2aef431-0a4c-4c52-aef0-b64cbdf7a5fe','role','authenticated')::text, true);

  -- A washed Clothes customer that needs 2 or more trolleys, and a free trolley of a size it needs.
  for v_flow, v_planned in
    select f.production_flow_item_id, (public.validate_finish_trolley_selection(f.production_flow_item_id,array[]::text[],now())->>'planned_total')::int
    from public.production_flow_items f
    where f.product_code='CLOTHES' and f.flow_status='OPEN' and f.scheduled_for_date >= current_date - 3
    order by f.scheduled_for_date desc limit 60
  loop
    continue when coalesce(v_planned,0) < 2;
    for v_code in
      select t.trolley_code from public.trolleys t
      where t.active and t.deleted_at is null
        and t.trolley_type_id in (select (x->>'trolley_type_id')::uuid from jsonb_array_elements(public.validate_finish_trolley_selection(v_flow,array[]::text[],now())->'planned_requirements') x)
      limit 40
    loop
      r := public.validate_finish_trolley_selection(v_flow,array[v_code],now());
      exit when not coalesce((r->>'hard_block')::boolean,true);
      v_code := null;
    end loop;
    exit when v_code is not null;
  end loop;
  if v_code is null then raise exception 'Nao achei um customer com 2+ trolleys e um trolley livre para testar.'; end if;

  -- 1) One trolley scanned + No trolley yet for the rest: accepted as PENDING.
  r := public.finish_resolve_trolley_scan_status(v_flow,array[v_code],true,false,now());
  if r->>'status' <> 'PENDING' then raise exception 'Esperava PENDING com 1 trolley + pendente, veio %', r->>'status'; end if;

  -- 2) Nothing scanned + No trolley yet: still PENDING (as before).
  r := public.finish_resolve_trolley_scan_status(v_flow,array[]::text[],true,false,now());
  if r->>'status' <> 'PENDING' then raise exception 'Esperava PENDING sem trolley, veio %', r->>'status'; end if;

  -- 3) One trolley scanned, not pending, mismatch not accepted: still refused (as before).
  begin
    r := public.finish_resolve_trolley_scan_status(v_flow,array[v_code],false,false,now());
    raise exception 'Deveria recusar quantidade diferente sem aceitar';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'Trolley quantity/type does not match%' then raise; end if;
  end;

  -- 4) An unknown trolley code is still refused even with No trolley yet.
  begin
    r := public.finish_resolve_trolley_scan_status(v_flow,array['ZZ-NOT-A-TROLLEY-999'],true,false,now());
    raise exception 'Deveria recusar trolley que nao existe';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'One or more scanned trolleys cannot be used%' then raise; end if;
  end;

  if has_function_privilege('anon','public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamp with time zone)','EXECUTE') then raise exception 'anon nao pode executar'; end if;
  if has_function_privilege('authenticated','public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamp with time zone)','EXECUTE') then raise exception 'authenticated nao pode executar direto'; end if;

  raise exception 'TESTE OK - nada foi gravado. Customer testado com % trolleys, trolley %: 1 escaneado + resto pendente = PENDING.', v_planned, v_code;
end $t$;
