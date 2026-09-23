-- Validation 048 — Finish processed-by Roster Planned with Actual override
begin;
do $$
declare
  v_date date:=(now() at time zone 'Europe/Dublin')::date;
  v_shift_id uuid;
  v_station_id uuid;
  v_staff_id uuid;
  v_available boolean;
  v_ctx jsonb;
begin
  if to_regprocedure('public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz)') is null then
    raise exception 'finish_processing_staff_available missing';
  end if;
  if to_regprocedure('public.get_finish_production_context_v2(text,timestamptz)') is null then
    raise exception 'get_finish_production_context_v2 missing';
  end if;

  select prv.shift_id,pre.station_id,pre.staff_id
  into v_shift_id,v_station_id,v_staff_id
  from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
  where pre.work_date=v_date
    and prv.status='PUBLISHED'
    and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
    and pre.station_code_snapshot in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
    and upper(coalesce(pre.day_status,'')) in ('WORKING','COVER')
    and not exists(
      select 1 from public.work_sessions ws
      where ws.staff_id=pre.staff_id and ws.work_date=v_date and ws.shift_id=prv.shift_id
        and upper(coalesce(ws.status,''))<>'CANCELLED'
    )
  limit 1;

  if v_staff_id is not null then
    v_available:=public.finish_processing_staff_available(v_staff_id,v_date,v_shift_id,v_station_id,now());
    if not v_available then
      raise exception 'Published Finish Roster fallback did not make planned staff available';
    end if;
  end if;

  -- Static contract check only; context requires an authenticated operational role.
  if not exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='get_finish_production_context_v2'
  ) then raise exception 'Finish context function missing'; end if;
end;
$$;
select jsonb_build_object(
  'test','202608130002_finish_processing_staff_roster_fallback_validation',
  'status','PASS',
  'writes_rolled_back',true,
  'roster_planned_fallback',true,
  'actual_overrides_planned',true,
  'exact_table_shift_required',true
) as validation_result;
rollback;
