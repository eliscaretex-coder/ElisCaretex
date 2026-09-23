-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110007_sorting_wash_requires_trolley_contents_scan
--
-- Operational sequence:
--   dirty trolley unloaded -> Sorting staff selects priority -> scan trolley
--   -> identify customer/date/product -> remove bags / weigh -> load washer
--   -> start washer -> record Washing.
--
-- Therefore a new Washing customer selection is valid only after a physical
-- Trolley Reception CONTENTS scan identified that Customer + Product + Date.
--
-- EMPTY does not unlock Washing.
-- Existing historical Wash IDs remain queryable and correctable.
-- =====================================================================

begin;

create or replace function public.get_sorting_customer_board_v3(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_rows jsonb := '[]'::jsonb;
  v_unscheduled_scan_customers jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  with board_days as (
    select
      v_business_date as scheduled_for_date,
      'TODAY'::text as day_relation,
      0::integer as day_offset
    union all
    select
      v_business_date + 1,
      'TOMORROW'::text,
      1
  ),
  board_rows as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      extract(isodow from bd.scheduled_for_date)::smallint as scheduled_weekday,
      trim(to_char(bd.scheduled_for_date, 'Day')) as scheduled_weekday_name,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.expected_kg,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      r.route_id,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      coalesce((
        select sum(req.quantity)::integer
        from public.customer_schedule_trolley_requirements req
        where req.schedule_day_id = sd.schedule_day_id
          and req.owner_schedule_product_id = sp.schedule_product_id
          and req.active = true
      ), 0) as planned_trolley_quantity,
      (
        select count(*)::integer
        from public.sorting_trolley_intake_products stip
        join public.sorting_trolley_intakes sti
          on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
        where sti.customer_id = c.customer_id
          and sti.contents_status = 'CONTENTS'
          and stip.product_code = pt.product_code
          and stip.source_schedule_product_id = sp.schedule_product_id
          and stip.scheduled_for_date = bd.scheduled_for_date
      ) as scan_contents_count,
      (
        select count(*)::integer
        from public.sorting_trolley_intake_products stip
        join public.sorting_trolley_intakes sti
          on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
        where sti.customer_id = c.customer_id
          and sti.contents_status = 'EMPTY'
          and stip.product_code = pt.product_code
          and stip.source_schedule_product_id = sp.schedule_product_id
          and stip.scheduled_for_date = bd.scheduled_for_date
      ) as scan_empty_count,
      (
        select min(sti.arrived_at)
        from public.sorting_trolley_intake_products stip
        join public.sorting_trolley_intakes sti
          on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
        where sti.customer_id = c.customer_id
          and sti.contents_status = 'CONTENTS'
          and stip.product_code = pt.product_code
          and stip.source_schedule_product_id = sp.schedule_product_id
          and stip.scheduled_for_date = bd.scheduled_for_date
      ) as first_contents_scan_at,
      (
        select max(sti.arrived_at)
        from public.sorting_trolley_intake_products stip
        join public.sorting_trolley_intakes sti
          on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
        where sti.customer_id = c.customer_id
          and sti.contents_status = 'CONTENTS'
          and stip.product_code = pt.product_code
          and stip.source_schedule_product_id = sp.schedule_product_id
          and stip.scheduled_for_date = bd.scheduled_for_date
      ) as last_contents_scan_at,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'trolley_code',sti.trolley_code_snapshot,
            'arrived_at',sti.arrived_at,
            'review_status',sti.review_status
          )
          order by sti.arrived_at
        )
        from public.sorting_trolley_intake_products stip
        join public.sorting_trolley_intakes sti
          on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
        where sti.customer_id = c.customer_id
          and sti.contents_status = 'CONTENTS'
          and stip.product_code = pt.product_code
          and stip.source_schedule_product_id = sp.schedule_product_id
          and stip.scheduled_for_date = bd.scheduled_for_date
      ),'[]'::jsonb) as contents_scans,
      (
        select count(*)::integer
        from public.sorting_wash_run_customers wrc
        join public.sorting_wash_runs wr
          on wr.wash_run_id = wrc.wash_run_id
        where wr.status = 'RECORDED'
          and wrc.customer_id = c.customer_id
          and wrc.wash_type_snapshot = pt.product_code
          and wrc.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc.scheduled_for_date, wr.business_date) = bd.scheduled_for_date
      ) as wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2
          on wr2.wash_run_id = wrc2.wash_run_id
        where wr2.status = 'RECORDED'
          and wrc2.customer_id = c.customer_id
          and wrc2.wash_type_snapshot = pt.product_code
          and wrc2.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc2.scheduled_for_date, wr2.business_date) = bd.scheduled_for_date
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) as last_wash_code,
      (
        select wr3.business_date
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3
          on wr3.wash_run_id = wrc3.wash_run_id
        where wr3.status = 'RECORDED'
          and wrc3.customer_id = c.customer_id
          and wrc3.wash_type_snapshot = pt.product_code
          and wrc3.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc3.scheduled_for_date, wr3.business_date) = bd.scheduled_for_date
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) as last_washed_on
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status = 'PUBLISHED'
     and csv.effective_from <= bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until >= bd.scheduled_for_date)
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active = true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active = true
     and sd.production_weekday = extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id = sd.schedule_day_id
     and sp.active = true
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
     and pt.active = true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES', 'MOP')
    left join public.distribution_routes r
      on r.route_id = sd.default_route_id
     and r.deleted_at is null
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', br.customer_id,
      'customer_code', br.customer_code,
      'customer_name', br.customer_name,
      'product_code', br.product_code,
      'production_order', br.production_order,
      'expected_kg', br.expected_kg,
      'production_instructions', br.production_instructions,
      'schedule_version_id', br.schedule_version_id,
      'schedule_day_id', br.schedule_day_id,
      'schedule_product_id', br.schedule_product_id,
      'scheduled_for_date', br.scheduled_for_date,
      'scheduled_weekday', br.scheduled_weekday,
      'scheduled_weekday_name', br.scheduled_weekday_name,
      'day_relation', br.day_relation,
      'day_offset', br.day_offset,
      'route_id', br.route_id,
      'route_code', br.route_code,
      'route_display_name', br.route_display_name,
      'route_color', br.route_color,
      'planned_trolley_quantity', br.planned_trolley_quantity,
      'scan_contents_count', br.scan_contents_count,
      'scan_empty_count', br.scan_empty_count,
      'first_contents_scan_at', br.first_contents_scan_at,
      'last_contents_scan_at', br.last_contents_scan_at,
      'contents_scans', br.contents_scans,
      'wash_enabled', br.scan_contents_count > 0,
      'wash_gate_status', case
        when br.scan_contents_count > 0 then 'READY_TO_WASH'
        when br.scan_empty_count > 0 then 'EMPTY_ONLY'
        else 'WAITING_SCAN'
      end,
      'wash_count', br.wash_count,
      'last_wash_code', br.last_wash_code,
      'last_washed_on', br.last_washed_on,
      'status', case when br.wash_count > 0 then 'WASHED' else 'PENDING' end
    )
    order by
      br.day_offset,
      case br.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
      br.production_order nulls last,
      lower(br.customer_name),
      br.customer_code
  ), '[]'::jsonb)
  into v_rows
  from board_rows br;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', q.customer_id,
      'customer_name', q.customer_name,
      'product_code', q.product_code,
      'contents_count', q.contents_count,
      'first_contents_scan_at', q.first_contents_scan_at,
      'last_contents_scan_at', q.last_contents_scan_at,
      'trolley_codes', q.trolley_codes
    )
    order by lower(q.customer_name), q.product_code
  ),'[]'::jsonb)
  into v_unscheduled_scan_customers
  from (
    select
      sti.customer_id,
      max(sti.customer_name_snapshot) as customer_name,
      stip.product_code,
      count(*)::integer as contents_count,
      min(sti.arrived_at) as first_contents_scan_at,
      max(sti.arrived_at) as last_contents_scan_at,
      jsonb_agg(sti.trolley_code_snapshot order by sti.arrived_at) as trolley_codes
    from public.sorting_trolley_intake_products stip
    join public.sorting_trolley_intakes sti
      on sti.sorting_trolley_intake_id = stip.sorting_trolley_intake_id
    where sti.business_date = v_business_date
      and sti.contents_status = 'CONTENTS'
    group by sti.customer_id, stip.product_code
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'customers', v_rows,
    'unscheduled_scan_customers', v_unscheduled_scan_customers,
    'wash_scan_gate_required', true,
    'source', 'PUBLISHED_CUSTOMER_SCHEDULE_TODAY_AND_TOMORROW_PLUS_TROLLEY_CONTENT_SCAN'
  );
end;
$$;


-- ---------------------------------------------------------------------
-- Private authoritative scan-gate assertion
-- ---------------------------------------------------------------------

create or replace function public.sorting_assert_wash_scan_gate(
  p_business_date date,
  p_wash_type text,
  p_customer_selections jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_type text := upper(trim(coalesce(p_wash_type,'')));
  v_product_code text;
  v_selection record;
  v_customer_id uuid;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_customer_name text;
  v_contents_count integer;
  v_empty_count integer;
begin
  if p_customer_selections is null
     or jsonb_typeof(p_customer_selections) <> 'array'
     or jsonb_array_length(p_customer_selections)=0 then
    raise exception using
      errcode='22023',
      message='At least one customer selection is required.';
  end if;

  v_product_code := case
    when v_type='MOP' then 'MOP'
    when v_type in ('CLOTHES','OTHERS') then 'CLOTHES'
    else null
  end;

  if v_product_code is null then
    raise exception using
      errcode='22023',
      message='Wash type is not supported by the trolley scan gate.';
  end if;

  for v_selection in
    select value
    from jsonb_array_elements(p_customer_selections)
  loop
    v_customer_id := nullif(v_selection.value->>'customer_id','')::uuid;
    v_schedule_product_id := nullif(v_selection.value->>'schedule_product_id','')::uuid;
    v_scheduled_for_date := nullif(v_selection.value->>'scheduled_for_date','')::date;

    if v_customer_id is null then
      raise exception using
        errcode='22023',
        message='Every Washing customer selection requires a valid customer.';
    end if;

    if (v_schedule_product_id is null) <> (v_scheduled_for_date is null) then
      raise exception using
        errcode='22023',
        message='Scheduled Washing selection requires both Scheduled Date and schedule product.';
    end if;

    select c.customer_name
    into v_customer_name
    from public.customers c
    where c.customer_id=v_customer_id
    limit 1;

    if v_schedule_product_id is not null then
      select
        count(*) filter (where sti.contents_status='CONTENTS')::integer,
        count(*) filter (where sti.contents_status='EMPTY')::integer
      into v_contents_count,v_empty_count
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti
        on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      where sti.customer_id=v_customer_id
        and stip.product_code=v_product_code
        and stip.source_schedule_product_id=v_schedule_product_id
        and stip.scheduled_for_date=v_scheduled_for_date;
    else
      -- Off-schedule / OTHERS path: require same operational Business Date.
      select
        count(*) filter (where sti.contents_status='CONTENTS')::integer,
        count(*) filter (where sti.contents_status='EMPTY')::integer
      into v_contents_count,v_empty_count
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti
        on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      where sti.customer_id=v_customer_id
        and stip.product_code=v_product_code
        and sti.business_date=p_business_date;
    end if;

    if coalesce(v_contents_count,0)=0 then
      if coalesce(v_empty_count,0)>0 then
        raise exception using
          errcode='22023',
          message=format(
            '%s has only EMPTY trolley receipt evidence for this Washing selection. Washing remains locked until laundry contents are identified by scan.',
            coalesce(v_customer_name,'Selected customer')
          );
      end if;

      raise exception using
        errcode='22023',
        message=format(
          'Scan and identify %s before recording Washing. A CONTENTS trolley receipt is required for the selected Customer + Date + Product.',
          coalesce(v_customer_name,'the selected customer')
        );
    end if;
  end loop;
end;
$$;

revoke all on function public.sorting_assert_wash_scan_gate(date,text,jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Browser-facing Washing writes with mandatory scan gate
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_wash_run_v3(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
begin
  perform public.require_sorting_operational_access();

  perform public.sorting_assert_wash_scan_gate(
    v_business_date,
    p_wash_type,
    p_customer_selections
  );

  return public.save_sorting_wash_run_v2(
    p_shift_code,
    p_washer_id,
    p_operator_staff_id,
    p_start_time,
    p_weight_kg,
    p_wash_type,
    p_customer_selections,
    p_notes
  );
end;
$$;

create or replace function public.save_sorting_missed_wash_v3(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
begin
  perform public.require_sorting_operational_access();

  perform public.sorting_assert_wash_scan_gate(
    v_business_date,
    p_wash_type,
    p_customer_selections
  );

  return public.save_sorting_missed_wash_v2(
    p_shift_code,
    p_washer_id,
    p_operator_staff_id,
    p_start_time,
    p_weight_kg,
    p_wash_type,
    p_customer_selections,
    p_notes,
    p_reason
  );
end;
$$;

create or replace function public.correct_sorting_wash_run_v3(
  p_wash_run_id uuid,
  p_expected_row_version integer,
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_old public.sorting_wash_runs%rowtype;
  v_old_keys text[];
  v_new_keys text[];
begin
  perform public.require_sorting_operational_access();

  select *
  into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id=p_wash_run_id;

  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  select array_agg(key order by key)
  into v_old_keys
  from (
    select case
      when wrc.source_schedule_product_id is not null
       and wrc.scheduled_for_date is not null
        then 'S:' || wrc.source_schedule_product_id::text || ':' || wrc.scheduled_for_date::text
      else 'U:' || wrc.customer_id::text
    end as key
    from public.sorting_wash_run_customers wrc
    where wrc.wash_run_id=p_wash_run_id
  ) q;

  select array_agg(key order by key)
  into v_new_keys
  from (
    select case
      when nullif(value->>'schedule_product_id','') is not null
       and nullif(value->>'scheduled_for_date','') is not null
        then 'S:' || (value->>'schedule_product_id') || ':' || (value->>'scheduled_for_date')
      else 'U:' || (value->>'customer_id')
    end as key
    from jsonb_array_elements(coalesce(p_customer_selections,'[]'::jsonb))
  ) q;

  -- Historical correction exception:
  -- changing only KG / washer / operator / time is allowed for a legacy Wash ID
  -- whose customer/date/type evidence predates the scan gate.
  -- Any customer/date/type change must satisfy the new scan gate.
  if upper(trim(coalesce(p_wash_type,''))) <> v_old.wash_type
     or v_new_keys is distinct from v_old_keys then
    perform public.sorting_assert_wash_scan_gate(
      v_business_date,
      p_wash_type,
      p_customer_selections
    );
  end if;

  return public.correct_sorting_wash_run_v2(
    p_wash_run_id,
    p_expected_row_version,
    p_shift_code,
    p_washer_id,
    p_operator_staff_id,
    p_start_time,
    p_weight_kg,
    p_wash_type,
    p_customer_selections,
    p_notes,
    p_reason
  );
end;
$$;

-- Browser must not use old write versions to bypass the scan gate.
revoke execute on function public.save_sorting_wash_run_v2(
  text,uuid,uuid,time,numeric,text,jsonb,text
) from authenticated;

revoke execute on function public.save_sorting_missed_wash_v2(
  text,uuid,uuid,time,numeric,text,jsonb,text,text
) from authenticated;

revoke execute on function public.correct_sorting_wash_run_v2(
  uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text
) from authenticated;

revoke all on function public.save_sorting_wash_run_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text
) from public, anon, authenticated;
revoke all on function public.save_sorting_missed_wash_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text,text
) from public, anon, authenticated;
revoke all on function public.correct_sorting_wash_run_v3(
  uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text
) from public, anon, authenticated;

grant execute on function public.save_sorting_wash_run_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text
) to authenticated;
grant execute on function public.save_sorting_missed_wash_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text,text
) to authenticated;
grant execute on function public.correct_sorting_wash_run_v3(
  uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text
) to authenticated;

comment on function public.save_sorting_wash_run_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text
) is
  'Authoritative live Washing write. Every selected customer must have prior Sorting Trolley Reception CONTENTS evidence for the matching Customer + Product + Scheduled Date before Washing can be recorded.';

comment on function public.save_sorting_missed_wash_v3(
  text,uuid,uuid,time,numeric,text,jsonb,text,text
) is
  'Late-entry Washing write with the same mandatory prior Trolley CONTENTS scan gate.';

comment on function public.correct_sorting_wash_run_v3(
  uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text
) is
  'Correction write. Legacy same-customer/date/type corrections remain possible; changing Customer, Scheduled Date or Type requires prior Trolley CONTENTS scan evidence.';

commit;
