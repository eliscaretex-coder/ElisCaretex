-- ElisCaretex V2
-- Sorting trolley intake correction and cancellation with preserved audit history.

begin;

alter table public.sorting_trolley_intakes
  add column if not exists record_status text not null default 'RECORDED',
  add column if not exists revision_no integer not null default 1,
  add column if not exists corrected_at timestamptz,
  add column if not exists corrected_by_auth_user_id uuid references auth.users(id) on delete set null,
  add column if not exists correction_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by_auth_user_id uuid references auth.users(id) on delete set null,
  add column if not exists cancellation_reason text;

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_record_status_check;

alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_record_status_check
  check (record_status in ('RECORDED','CANCELLED'));

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_revision_no_check;

alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_revision_no_check
  check (revision_no >= 1);

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_relation_check;

alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_relation_check
  check (schedule_relation in ('YESTERDAY','TODAY','TOMORROW','FUTURE','PAST_CORRECTION','OFF_SCHEDULE'));

create table if not exists public.sorting_trolley_intake_revisions (
  sorting_trolley_intake_revision_id uuid primary key default gen_random_uuid(),
  sorting_trolley_intake_id uuid not null references public.sorting_trolley_intakes(sorting_trolley_intake_id) on delete restrict,
  revision_no integer not null,
  action_type text not null,
  reason text not null,
  before_data jsonb not null,
  after_data jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by_auth_user_id uuid references auth.users(id) on delete set null,
  changed_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  constraint sorting_trolley_intake_revisions_action_check
    check (action_type in ('CORRECTED','CANCELLED')),
  constraint sorting_trolley_intake_revisions_revision_check
    check (revision_no >= 1),
  unique (sorting_trolley_intake_id, revision_no)
);

alter table public.sorting_trolley_intake_revisions enable row level security;
revoke all on public.sorting_trolley_intake_revisions from public, anon, authenticated;

create index if not exists sorting_trolley_intakes_record_status_idx
  on public.sorting_trolley_intakes(business_date, shift_id, record_status, arrived_at desc);

create index if not exists sorting_trolley_intake_revisions_intake_idx
  on public.sorting_trolley_intake_revisions(sorting_trolley_intake_id, revision_no desc);

create or replace function public.sorting_schedule_relation_for_date(
  p_business_date date,
  p_scheduled_for_date date,
  p_allow_past_correction boolean default false
)
returns text
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
begin
  if p_business_date is null or p_scheduled_for_date is null then
    raise exception using errcode='22023', message='Scheduled Date is required.';
  end if;

  if p_scheduled_for_date < p_business_date-1 and not p_allow_past_correction then
    raise exception using errcode='22023', message='Scheduled Date cannot be earlier than yesterday for Sorting Intake.';
  end if;

  if p_scheduled_for_date > p_business_date+7 then
    raise exception using errcode='22023', message='Scheduled Date must be within the next 7 scheduled days for Sorting Intake.';
  end if;

  return case
    when p_scheduled_for_date=p_business_date-1 then 'YESTERDAY'
    when p_scheduled_for_date=p_business_date then 'TODAY'
    when p_scheduled_for_date=p_business_date+1 then 'TOMORROW'
    when p_scheduled_for_date>p_business_date+1 then 'FUTURE'
    else 'PAST_CORRECTION'
  end;
end;
$$;

create or replace function public.sorting_schedule_product_snapshot(
  p_customer_id uuid,
  p_product_code text,
  p_scheduled_for_date date
)
returns table(
  schedule_version_id uuid,
  schedule_day_id uuid,
  schedule_product_id uuid,
  production_order integer,
  planned_trolley_quantity integer,
  route_id uuid,
  route_code text,
  route_display_name text,
  route_color text
)
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_product text := upper(trim(coalesce(p_product_code,'')));
begin
  if p_customer_id is null or p_scheduled_for_date is null or v_product not in ('CLOTHES','MOP') then
    raise exception using errcode='22023', message='Schedule product lookup is incomplete.';
  end if;

  return query
  select
    csv.schedule_version_id,
    sd.schedule_day_id,
    sp.schedule_product_id,
    sp.production_order,
    coalesce((
      select sum(req.quantity)::integer
      from public.customer_schedule_trolley_requirements req
      where req.schedule_day_id=sd.schedule_day_id
        and req.owner_schedule_product_id=sp.schedule_product_id
        and req.active=true
    ),0) as planned_trolley_quantity,
    r.route_id,
    r.route_code,
    r.display_name,
    r.route_color
  from public.customer_schedule_versions csv
  join public.customer_schedule_days sd
    on sd.schedule_version_id=csv.schedule_version_id
   and sd.active=true
   and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
  join public.customer_schedule_products sp
    on sp.schedule_day_id=sd.schedule_day_id
   and sp.active=true
  join public.product_types pt
    on pt.product_type_id=sp.product_type_id
   and pt.active=true
   and pt.deleted_at is null
   and pt.product_code=v_product
  left join public.distribution_routes r
    on r.route_id=sd.default_route_id
   and r.deleted_at is null
  where csv.customer_id=p_customer_id
    and csv.status='PUBLISHED'
    and csv.effective_from<=p_scheduled_for_date
    and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
  order by csv.effective_from desc,csv.version_number desc
  limit 1;

  if not found then
    raise exception using errcode='22023', message='Selected customer/product is not published for the selected Scheduled Date.';
  end if;
end;
$$;

create or replace function public.correct_sorting_trolley_intake(
  p_sorting_trolley_intake_id uuid,
  p_customer_id uuid,
  p_scheduled_for_date date,
  p_product_codes text[],
  p_contents_status text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_intake public.sorting_trolley_intakes%rowtype;
  v_customer public.customers%rowtype;
  v_business_date date;
  v_relation text;
  v_contents text := upper(trim(coalesce(p_contents_status,'')));
  v_products text[];
  v_product text;
  v_product_scope text;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_actor_staff_id uuid := public.current_staff_id();
  v_old_flow_ids uuid[];
  v_new_flow_id uuid;
  v_snapshot record;
  v_downstream_wash_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  if p_sorting_trolley_intake_id is null then
    raise exception using errcode='22023', message='Trolley intake record is required.';
  end if;

  if v_reason is null then
    raise exception using errcode='22023', message='Correction reason is required.';
  end if;

  if v_contents not in ('CONTENTS','EMPTY') then
    raise exception using errcode='22023', message='Choose Laundry inside or Empty trolley.';
  end if;

  select *
  into v_intake
  from public.sorting_trolley_intakes
  where sorting_trolley_intake_id=p_sorting_trolley_intake_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Trolley intake record was not found.';
  end if;

  if v_intake.record_status='CANCELLED' then
    raise exception using errcode='22023', message='Cancelled trolley intake cannot be edited.';
  end if;

  v_business_date := v_intake.business_date;
  v_relation := public.sorting_schedule_relation_for_date(v_business_date,p_scheduled_for_date,true);

  select *
  into v_customer
  from public.customers
  where customer_id=p_customer_id
    and active=true
    and deleted_at is null;

  if not found then
    raise exception using errcode='22023', message='Confirmed customer is not active.';
  end if;

  select array_agg(distinct upper(trim(x)) order by upper(trim(x)))
  into v_products
  from unnest(coalesce(p_product_codes,array[]::text[])) x
  where upper(trim(x)) in ('CLOTHES','MOP');

  if coalesce(array_length(v_products,1),0)=0 or array_length(v_products,1)>2 then
    raise exception using errcode='22023', message='Choose Clothes, MOP or Both.';
  end if;

  select coalesce(count(*),0)
  into v_downstream_wash_count
  from public.sorting_trolley_intake_products stip
  join public.sorting_wash_run_customers wrc on wrc.production_flow_item_id=stip.production_flow_item_id
  join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED'
  where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  if v_downstream_wash_count>0 and (
    v_contents is distinct from v_intake.contents_status
    or array(select unnest(v_products) order by 1) is distinct from array(
      select product_code from public.sorting_trolley_intake_products
      where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
      order by product_code
    )
  ) then
    raise exception using errcode='22023', message='This trolley has already been washed. Customer and Scheduled Date can be corrected, but product and contents must stay unchanged.';
  end if;

  v_before := to_jsonb(v_intake) || jsonb_build_object(
    'products',coalesce((
      select jsonb_agg(to_jsonb(stip) order by stip.product_code)
      from public.sorting_trolley_intake_products stip
      where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
    ),'[]'::jsonb)
  );

  select array_agg(distinct production_flow_item_id)
  into v_old_flow_ids
  from public.sorting_trolley_intake_products
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  delete from public.sorting_trolley_intake_products
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  v_product_scope := case when array_length(v_products,1)=2 then 'BOTH' else v_products[1] end;

  update public.sorting_trolley_intakes
  set customer_id=v_customer.customer_id,
      customer_code_snapshot=v_customer.customer_code,
      customer_name_snapshot=v_customer.customer_name,
      contents_status=v_contents,
      product_scope=v_product_scope,
      scheduled_for_date=p_scheduled_for_date,
      schedule_relation=v_relation,
      off_schedule_reason=null,
      off_schedule_code=null,
      correction_reason=v_reason,
      corrected_at=now(),
      corrected_by_auth_user_id=auth.uid(),
      revision_no=revision_no+1
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
  returning revision_no into v_revision;

  foreach v_product in array v_products loop
    select * into v_snapshot
    from public.sorting_schedule_product_snapshot(v_customer.customer_id,v_product,p_scheduled_for_date);

    v_new_flow_id := public.ensure_production_flow_item(
      v_customer.customer_id,
      v_product,
      p_scheduled_for_date,
      v_business_date,
      v_snapshot.schedule_version_id,
      v_snapshot.schedule_day_id,
      v_snapshot.schedule_product_id,
      v_snapshot.production_order,
      v_snapshot.route_id,
      v_snapshot.route_code,
      v_snapshot.route_display_name,
      v_snapshot.route_color
    );

    insert into public.sorting_trolley_intake_products(
      sorting_trolley_intake_id, product_code, scheduled_for_date,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id,
      production_order_snapshot, planned_trolley_quantity_snapshot,
      route_id_snapshot, route_code_snapshot, route_display_name_snapshot, route_color_snapshot,
      production_flow_item_id
    )
    values(
      v_intake.sorting_trolley_intake_id, v_product, p_scheduled_for_date,
      v_snapshot.schedule_version_id, v_snapshot.schedule_day_id, v_snapshot.schedule_product_id,
      v_snapshot.production_order, v_snapshot.planned_trolley_quantity,
      v_snapshot.route_id, v_snapshot.route_code, v_snapshot.route_display_name, v_snapshot.route_color,
      v_new_flow_id
    );

    if v_downstream_wash_count>0 then
      update public.sorting_wash_run_customers wrc
      set customer_id=v_customer.customer_id,
          customer_code_snapshot=v_customer.customer_code,
          customer_name_snapshot=v_customer.customer_name,
          source_schedule_version_id=v_snapshot.schedule_version_id,
          source_schedule_day_id=v_snapshot.schedule_day_id,
          source_schedule_product_id=v_snapshot.schedule_product_id,
          production_order_snapshot=v_snapshot.production_order,
          scheduled_for_date=p_scheduled_for_date,
          schedule_relation=case when p_scheduled_for_date=v_business_date then 'TODAY' else 'UNSCHEDULED' end,
          production_flow_item_id=v_new_flow_id
      where wrc.production_flow_item_id=any(coalesce(v_old_flow_ids,array[]::uuid[]))
        and wrc.wash_type_snapshot=v_product;

      perform public.refresh_production_flow_wash_summary(v_new_flow_id);
    end if;

    perform public.append_production_flow_event(
      v_new_flow_id,'TROLLEY_INTAKE_CORRECTED','INTAKE',20,'SORTING',
      v_business_date,now(),v_intake.operator_staff_id,v_actor_staff_id,auth.uid(),
      'SORTING_V2','sorting_trolley_intake_revisions',v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,
      jsonb_build_object('reason',v_reason,'scheduled_for_date',p_scheduled_for_date,'schedule_relation',v_relation,'product_code',v_product)
    );
  end loop;

  if v_old_flow_ids is not null then
    foreach v_new_flow_id in array v_old_flow_ids loop
      perform public.refresh_production_flow_wash_summary(v_new_flow_id);
    end loop;
  end if;

  select to_jsonb(sti) || jsonb_build_object(
    'products',coalesce((
      select jsonb_agg(to_jsonb(stip) order by stip.product_code)
      from public.sorting_trolley_intake_products stip
      where stip.sorting_trolley_intake_id=sti.sorting_trolley_intake_id
    ),'[]'::jsonb)
  )
  into v_after
  from public.sorting_trolley_intakes sti
  where sti.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  insert into public.sorting_trolley_intake_revisions(
    sorting_trolley_intake_id,revision_no,action_type,reason,before_data,after_data,
    changed_by_auth_user_id,changed_by_staff_id
  )
  values(
    v_intake.sorting_trolley_intake_id,v_revision,'CORRECTED',v_reason,v_before,v_after,
    auth.uid(),v_actor_staff_id
  );

  return jsonb_build_object('status','corrected','revision_no',v_revision,'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id);
end;
$$;

create or replace function public.cancel_sorting_trolley_intake(
  p_sorting_trolley_intake_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_intake public.sorting_trolley_intakes%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_before jsonb;
  v_after jsonb;
  v_revision integer;
  v_actor_staff_id uuid := public.current_staff_id();
  v_flow_id uuid;
begin
  perform public.require_sorting_operational_access();

  if p_sorting_trolley_intake_id is null then
    raise exception using errcode='22023', message='Trolley intake record is required.';
  end if;

  if v_reason is null then
    raise exception using errcode='22023', message='Removal reason is required.';
  end if;

  select *
  into v_intake
  from public.sorting_trolley_intakes
  where sorting_trolley_intake_id=p_sorting_trolley_intake_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Trolley intake record was not found.';
  end if;

  if v_intake.record_status='CANCELLED' then
    raise exception using errcode='22023', message='Trolley intake is already cancelled.';
  end if;

  v_before := to_jsonb(v_intake) || jsonb_build_object(
    'products',coalesce((
      select jsonb_agg(to_jsonb(stip) order by stip.product_code)
      from public.sorting_trolley_intake_products stip
      where stip.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
    ),'[]'::jsonb)
  );

  update public.sorting_trolley_intakes
  set record_status='CANCELLED',
      cancellation_reason=v_reason,
      cancelled_at=now(),
      cancelled_by_auth_user_id=auth.uid(),
      revision_no=revision_no+1
  where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
  returning revision_no into v_revision;

  select to_jsonb(sti) into v_after
  from public.sorting_trolley_intakes sti
  where sti.sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id;

  insert into public.sorting_trolley_intake_revisions(
    sorting_trolley_intake_id,revision_no,action_type,reason,before_data,after_data,
    changed_by_auth_user_id,changed_by_staff_id
  )
  values(
    v_intake.sorting_trolley_intake_id,v_revision,'CANCELLED',v_reason,v_before,v_after,
    auth.uid(),v_actor_staff_id
  );

  for v_flow_id in
    select distinct production_flow_item_id
    from public.sorting_trolley_intake_products
    where sorting_trolley_intake_id=v_intake.sorting_trolley_intake_id
  loop
    perform public.append_production_flow_event(
      v_flow_id,'TROLLEY_INTAKE_CANCELLED','INTAKE',20,'SORTING',
      v_intake.business_date,now(),v_intake.operator_staff_id,v_actor_staff_id,auth.uid(),
      'SORTING_V2','sorting_trolley_intake_revisions',v_intake.sorting_trolley_intake_id::text || ':' || v_revision::text,
      jsonb_build_object('reason',v_reason,'trolley_code',v_intake.trolley_code_snapshot,'customer_id',v_intake.customer_id)
    );
    perform public.refresh_production_flow_wash_summary(v_flow_id);
  end loop;

  return jsonb_build_object('status','cancelled','revision_no',v_revision,'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id);
end;
$$;

create or replace function public.terminal_correct_sorting_trolley_intake(
  p_sorting_trolley_intake_id uuid,
  p_customer_id uuid,
  p_scheduled_for_date date,
  p_product_codes text[],
  p_contents_status text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.correct_sorting_trolley_intake(p_sorting_trolley_intake_id,p_customer_id,p_scheduled_for_date,p_product_codes,p_contents_status,p_reason);
end;
$$;

create or replace function public.terminal_cancel_sorting_trolley_intake(
  p_sorting_trolley_intake_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.cancel_sorting_trolley_intake(p_sorting_trolley_intake_id,p_reason);
end;
$$;

do $migration$
declare
  v_sql text;
begin
  select pg_get_functiondef('public.get_sorting_trolley_intake_context_v2(text)'::regprocedure) into v_sql;

  v_sql := replace(v_sql,
    'and sti.customer_id=s.customer_id',
    'and sti.customer_id=s.customer_id
        and coalesce(sti.record_status,''RECORDED'')=''RECORDED'''
  );

  v_sql := replace(v_sql,
    'where sti.business_date=v_business_date
      and sti.shift_id=v_shift_id
    order by sti.arrived_at desc',
    'where sti.business_date=v_business_date
      and sti.shift_id=v_shift_id
    order by sti.arrived_at desc'
  );

  v_sql := replace(v_sql,
    '''notes'',q.notes,',
    '''notes'',q.notes,
      ''record_status'',coalesce(q.record_status,''RECORDED''),
      ''revision_no'',q.revision_no,
      ''correction_reason'',q.correction_reason,
      ''cancellation_reason'',q.cancellation_reason,
      ''corrected_at'',q.corrected_at,
      ''cancelled_at'',q.cancelled_at,'
  );

  v_sql := replace(v_sql,
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
      ),
      ''contents_today''',
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and coalesce(sti.record_status,''RECORDED'')=''RECORDED''
      ),
      ''contents_today'''
  );

  v_sql := replace(v_sql,
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status=''CONTENTS''',
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and coalesce(sti.record_status,''RECORDED'')=''RECORDED''
          and sti.contents_status=''CONTENTS'''
  );

  v_sql := replace(v_sql,
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status=''EMPTY''',
    'where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and coalesce(sti.record_status,''RECORDED'')=''RECORDED''
          and sti.contents_status=''EMPTY'''
  );

  execute v_sql;
end $migration$;

revoke all on function public.correct_sorting_trolley_intake(uuid,uuid,date,text[],text,text) from public,anon,authenticated;
revoke all on function public.cancel_sorting_trolley_intake(uuid,text) from public,anon,authenticated;
revoke all on function public.terminal_correct_sorting_trolley_intake(uuid,uuid,date,text[],text,text) from public,anon,authenticated;
revoke all on function public.terminal_cancel_sorting_trolley_intake(uuid,text) from public,anon,authenticated;

grant execute on function public.terminal_correct_sorting_trolley_intake(uuid,uuid,date,text[],text,text) to authenticated;
grant execute on function public.terminal_cancel_sorting_trolley_intake(uuid,text) to authenticated;

comment on table public.sorting_trolley_intake_revisions is
  'Append-only audit history for Sorting trolley intake corrections and cancellations.';

commit;
