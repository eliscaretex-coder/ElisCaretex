-- Finish Production Registration: "No trolley yet" per plate.
-- Before: p_trolley_pending=true was refused when any trolley code was scanned, so the
-- staff could only mark the whole customer as "no trolley yet". Now the scanned trolleys
-- are saved and linked as usual, and the record keeps trolley_scan_status='PENDING'
-- until the missing plates are scanned through Edit. Unusable trolleys still block.
create or replace function public.finish_resolve_trolley_scan_status(
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
$function$;

-- Internal helper: same privileges as before (only the owner and service_role).
revoke all on function public.finish_resolve_trolley_scan_status(uuid,text[],boolean,boolean,timestamp with time zone) from public, anon, authenticated;
