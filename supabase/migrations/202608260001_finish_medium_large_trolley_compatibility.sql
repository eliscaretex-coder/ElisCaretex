-- Medium trolley requirements can use a Large trolley when needed.
-- Large remains distinct when explicitly planned, so an available Large trolley
-- is allocated to a Large requirement before being counted toward Medium.

create or replace function public.validate_finish_trolley_selection(
  p_production_flow_item_id uuid,
  p_trolley_codes text[] default array[]::text[],
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_delivery date;
  v_cutoff timestamptz;
  v_plan jsonb := '[]'::jsonb;
  v_plan_total integer := 0;
  v_scanned jsonb := '[]'::jsonb;
  v_hard_issues jsonb := '[]'::jsonb;
  v_plan_issues jsonb := '[]'::jsonb;
  v_code text;
  v_trolley public.trolleys%rowtype;
  v_type public.trolley_types%rowtype;
  v_open_stay public.trolley_customer_stays%rowtype;
  v_same_flow boolean;
  v_have integer;
  v_medium_scanned integer := 0;
  v_large_scanned integer := 0;
  v_planned_large_qty integer := 0;
  v_req record;
  v_extra record;
  v_scanned_total integer := 0;
  v_matches_plan boolean := true;
begin
  perform public.require_finish_production_access();

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id;

  if not found or v_flow.product_code<>'CLOTHES' then
    raise exception using errcode='22023', message='A valid CLOTHES Production Flow item is required.';
  end if;

  select x.delivery_date,x.edit_cutoff_at
  into v_delivery,v_cutoff
  from public.finish_assert_entry_open(v_flow.production_flow_item_id,coalesce(p_at,now())) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'trolley_type_id',tt.trolley_type_id,
      'trolley_type_code',tt.trolley_type_code,
      'display_code',coalesce(tt.display_code,tt.trolley_type_code),
      'trolley_type_name',tt.trolley_type_name,
      'quantity',r.quantity,
      'empty_trolley',r.empty_trolley
    ) order by tt.sort_order,tt.trolley_type_code),'[]'::jsonb),
    coalesce(sum(r.quantity),0)::integer
  into v_plan,v_plan_total
  from public.customer_schedule_trolley_requirements r
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where r.active=true
    and r.owner_schedule_product_id=v_flow.source_schedule_product_id;

  for v_code in
    select distinct upper(trim(x))
    from unnest(coalesce(p_trolley_codes,array[]::text[])) x
    where nullif(trim(x),'') is not null
    order by upper(trim(x))
  loop
    v_scanned_total := v_scanned_total + 1;
    v_same_flow := false;

    select * into v_trolley
    from public.trolleys t
    where lower(t.trolley_code)=lower(v_code)
      and t.deleted_at is null;

    if not found then
      v_scanned := v_scanned || jsonb_build_array(jsonb_build_object(
        'trolley_code',v_code,'exists',false,'usable',false,'issue','NOT_FOUND'
      ));
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley not found.',v_code));
      continue;
    end if;

    select * into v_type
    from public.trolley_types tt
    where tt.trolley_type_id=v_trolley.trolley_type_id;

    select * into v_open_stay
    from public.trolley_customer_stays s
    where s.trolley_id=v_trolley.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1;

    select exists(
      select 1
      from public.finish_production_trolleys ft
      join public.finish_production_entries e on e.finish_production_entry_id=ft.finish_production_entry_id
      where ft.trolley_id=v_trolley.trolley_id
        and e.production_flow_item_id=v_flow.production_flow_item_id
        and e.status='ACTIVE'
    ) into v_same_flow;

    if not coalesce(v_trolley.active,false) or v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley is %s.',v_trolley.trolley_code,v_trolley.status));
    elsif v_open_stay.stay_id is not null
          and (not v_same_flow or v_open_stay.outbound_customer_id is distinct from v_flow.customer_id) then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley already has an open customer stay for another production/customer.',v_trolley.trolley_code));
    elsif v_open_stay.stay_id is null and v_trolley.status not in ('AVAILABLE','LOCATION_UNCONFIRMED') then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley cannot be assigned from Finish while status is %s.',v_trolley.trolley_code,v_trolley.status));
    end if;

    v_scanned := v_scanned || jsonb_build_array(jsonb_build_object(
      'trolley_id',v_trolley.trolley_id,
      'trolley_code',v_trolley.trolley_code,
      'exists',true,
      'active',v_trolley.active,
      'stored_status',v_trolley.status,
      'trolley_type_id',v_type.trolley_type_id,
      'trolley_type_code',v_type.trolley_type_code,
      'display_code',coalesce(v_type.display_code,v_type.trolley_type_code),
      'trolley_type_name',v_type.trolley_type_name,
      'same_finish_flow',v_same_flow,
      'open_stay_id',v_open_stay.stay_id,
      'open_stay_customer_id',v_open_stay.outbound_customer_id,
      'usable',(
        coalesce(v_trolley.active,false)
        and v_trolley.status not in ('OUT_OF_SERVICE','RETIRED')
        and (
          (v_open_stay.stay_id is not null and v_same_flow and v_open_stay.outbound_customer_id=v_flow.customer_id)
          or (v_open_stay.stay_id is null and v_trolley.status in ('AVAILABLE','LOCATION_UNCONFIRMED'))
        )
      )
    ));
  end loop;

  select
    count(*) filter (where upper(coalesce(d->>'trolley_type_code',''))='MEDIUM')::integer,
    count(*) filter (where upper(coalesce(d->>'trolley_type_code',''))='LARGE')::integer
  into v_medium_scanned,v_large_scanned
  from jsonb_array_elements(v_scanned) d
  where coalesce((d->>'exists')::boolean,false)=true;

  select coalesce(sum(r.quantity),0)::integer
  into v_planned_large_qty
  from public.customer_schedule_trolley_requirements r
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where r.active=true
    and r.owner_schedule_product_id=v_flow.source_schedule_product_id
    and upper(tt.trolley_type_code)='LARGE';

  for v_req in
    select r.trolley_type_id,r.quantity,tt.trolley_type_code,coalesce(tt.display_code,tt.trolley_type_code) display_code,tt.trolley_type_name
    from public.customer_schedule_trolley_requirements r
    join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
    where r.active=true and r.owner_schedule_product_id=v_flow.source_schedule_product_id
    order by tt.sort_order,tt.trolley_type_code
  loop
    if upper(v_req.trolley_type_code)='MEDIUM' then
      -- Any Large trolley not needed by an explicit Large requirement can cover Medium.
      v_have := v_medium_scanned + greatest(0,v_large_scanned-v_planned_large_qty);
    else
      select count(*)::integer into v_have
      from jsonb_array_elements(v_scanned) d
      where coalesce((d->>'exists')::boolean,false)=true
        and d->>'trolley_type_id'=v_req.trolley_type_id::text;
    end if;

    if v_have<>v_req.quantity then
      v_matches_plan := false;
      v_plan_issues := v_plan_issues || jsonb_build_array(
        format('%s: planned %s, scanned %s.',v_req.display_code,v_req.quantity,v_have)
      );
    end if;
  end loop;

  for v_extra in
    select d->>'trolley_type_id' trolley_type_id,
      coalesce(d->>'display_code',d->>'trolley_type_code','Unknown') display_code,
      count(*)::integer qty
    from jsonb_array_elements(v_scanned) d
    where coalesce((d->>'exists')::boolean,false)=true
      and nullif(d->>'trolley_type_id','') is not null
      and not exists(
        select 1
        from public.customer_schedule_trolley_requirements r
        join public.trolley_types planned_type on planned_type.trolley_type_id=r.trolley_type_id
        where r.active=true
          and r.owner_schedule_product_id=v_flow.source_schedule_product_id
          and (
            r.trolley_type_id=(d->>'trolley_type_id')::uuid
            or (
              upper(planned_type.trolley_type_code)='MEDIUM'
              and upper(coalesce(d->>'trolley_type_code',''))='LARGE'
            )
          )
      )
    group by d->>'trolley_type_id',coalesce(d->>'display_code',d->>'trolley_type_code','Unknown')
  loop
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('%s: %s scanned but this type is not in the published plan.',v_extra.display_code,v_extra.qty)
    );
  end loop;

  if v_plan_total=0 and v_scanned_total>0 then
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('Published plan has no trolley requirement, but %s trolley(s) were scanned.',v_scanned_total)
    );
  elsif v_plan_total>0 and v_scanned_total<>v_plan_total and jsonb_array_length(v_plan_issues)=0 then
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('Published plan expects %s trolley(s); %s were scanned.',v_plan_total,v_scanned_total)
    );
  end if;

  return jsonb_build_object(
    'schema_version','FINISH_TROLLEY_SCAN_V1',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'customer_id',v_flow.customer_id,
    'customer_name',v_flow.customer_name_snapshot,
    'scheduled_for_date',v_flow.scheduled_for_date,
    'delivery_date',v_delivery,
    'edit_cutoff_at',v_cutoff,
    'planned_requirements',v_plan,
    'planned_total',v_plan_total,
    'scanned',v_scanned,
    'scanned_total',v_scanned_total,
    'matches_plan',v_matches_plan,
    'plan_issues',v_plan_issues,
    'hard_issues',v_hard_issues,
    'hard_block',jsonb_array_length(v_hard_issues)>0,
    'can_use_selection',jsonb_array_length(v_hard_issues)=0
  );
end;
$$;

comment on function public.validate_finish_trolley_selection(uuid,text[],timestamptz) is
  'Finish trolley scan precheck. Medium requirements may use unreserved Large trolleys; all other types remain exact.';
