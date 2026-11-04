-- ElisCaretex V2 - Sorting: mark a scheduled customer as "Nothing sent".
--
-- When a scheduled customer sends no trolley and no contents, Sorting can now record
-- that fact so the Today's Customers lists show "Nothing sent · nothing to process"
-- instead of "Waiting receipt". It is an append-only fact with cancellation (Undo),
-- never a deletion. It does not create a production flow item and does not change
-- Washing, MOP, Finish or the Production Tracker.
--
-- Objects:
--   table  sorting_customer_nothing_sent
--   rpc    get_sorting_customer_nothing_sent(p_date_from, p_date_to)          read
--   rpc    record_sorting_customer_nothing_sent(...)  + terminal_ wrapper     write
--   rpc    cancel_sorting_customer_nothing_sent(...)  + terminal_ wrapper     write
-- Writes follow the terminal pattern of 202608180001: only the registered Sorting
-- computer can call the terminal_ wrappers; the inner functions are not callable
-- by authenticated users directly.

create table if not exists public.sorting_customer_nothing_sent (
  sorting_customer_nothing_sent_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_name_snapshot text not null,
  product_code text not null,
  scheduled_for_date date not null,
  source_schedule_product_id uuid not null references public.customer_schedule_products(schedule_product_id) on delete restrict,
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  recorded_at timestamptz not null default now(),
  notes text,
  status text not null default 'RECORDED',
  cancelled_at timestamptz,
  cancelled_by_auth_user_id uuid references auth.users(id) on delete set null,
  cancellation_reason text,
  constraint sorting_customer_nothing_sent_product_check check (product_code in ('CLOTHES','MOP')),
  constraint sorting_customer_nothing_sent_status_check check (status in ('RECORDED','CANCELLED')),
  constraint sorting_customer_nothing_sent_cancel_check check (
    (status='RECORDED' and cancelled_at is null)
    or (status='CANCELLED' and cancelled_at is not null)
  )
);

create unique index if not exists sorting_customer_nothing_sent_active_uidx
  on public.sorting_customer_nothing_sent(source_schedule_product_id,scheduled_for_date)
  where status='RECORDED';

create index if not exists sorting_customer_nothing_sent_date_idx
  on public.sorting_customer_nothing_sent(scheduled_for_date,status);

alter table public.sorting_customer_nothing_sent enable row level security;
revoke all on table public.sorting_customer_nothing_sent from public,anon,authenticated;

comment on table public.sorting_customer_nothing_sent is
  'Sorting record that a scheduled customer product sent nothing (no trolley, no contents) for a Scheduled Date. Cancellation keeps history.';

-- ---------------------------------------------------------------------
-- Read: active "Nothing sent" marks for a Scheduled Date range (max 14 days).
-- ---------------------------------------------------------------------
create or replace function public.get_sorting_customer_nothing_sent(
  p_date_from date,
  p_date_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.require_sorting_operational_access();
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from>14 then
    raise exception using errcode='22023', message='Use a date range of up to 14 days.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'sorting_customer_nothing_sent_id',n.sorting_customer_nothing_sent_id,
      'customer_id',n.customer_id,
      'customer_name',n.customer_name_snapshot,
      'product_code',n.product_code,
      'scheduled_for_date',n.scheduled_for_date,
      'schedule_product_id',n.source_schedule_product_id,
      'operator_staff_id',n.operator_staff_id,
      'operator_name',coalesce(sm.display_name,''),
      'recorded_at',n.recorded_at,
      'notes',n.notes
    ) order by n.recorded_at)
    from public.sorting_customer_nothing_sent n
    left join public.staff_members sm on sm.staff_id=n.operator_staff_id
    where n.status='RECORDED'
      and n.scheduled_for_date between p_date_from and p_date_to
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.get_sorting_customer_nothing_sent(date,date) from public,anon;
grant execute on function public.get_sorting_customer_nothing_sent(date,date) to authenticated;

-- ---------------------------------------------------------------------
-- Write: record "Nothing sent".
-- ---------------------------------------------------------------------
create or replace function public.record_sorting_customer_nothing_sent(
  p_shift_code text,
  p_schedule_product_id uuid,
  p_scheduled_for_date date,
  p_operator_staff_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift record;
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_product record;
  v_staff_context jsonb;
  v_row public.sorting_customer_nothing_sent%rowtype;
begin
  perform public.require_sorting_operational_access();

  if p_schedule_product_id is null or p_scheduled_for_date is null or p_operator_staff_id is null then
    raise exception using errcode='22023', message='Customer, Scheduled Date and your name are required.';
  end if;
  if abs(p_scheduled_for_date-v_business_date)>2 then
    raise exception using errcode='22023', message='Nothing sent can only be recorded for yesterday, today or the next days.';
  end if;

  select sh.shift_id,sh.shift_code into v_shift
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true and sh.deleted_at is null
  limit 1;
  if v_shift.shift_id is null then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  v_staff_context := public.get_sorting_staff_dashboard_context_v2(v_shift.shift_code);
  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_staff_context->'staff','[]'::jsonb)) s
    where s.value->>'staff_id'=p_operator_staff_id::text
      and coalesce(s.value->>'attendance_status','') not in ('ABSENT','AUTO_ABSENT','MOVED')
      and coalesce((s.value->>'actual_in_sorting')::boolean,true)=true
  ) then
    raise exception using errcode='22023', message='Selected staff member is not currently available in Sorting.';
  end if;

  -- The schedule product must belong to a published schedule that covers the date
  -- and whose production weekday matches it.
  select c.customer_id,c.customer_name,pt.product_code
  into v_product
  from public.customer_schedule_products sp
  join public.customer_schedule_days sd on sd.schedule_day_id=sp.schedule_day_id and sd.active=true
  join public.customer_schedule_versions csv on csv.schedule_version_id=sd.schedule_version_id
  join public.customers c on c.customer_id=csv.customer_id and c.active=true and c.deleted_at is null
  join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code in ('CLOTHES','MOP')
  where sp.schedule_product_id=p_schedule_product_id
    and sp.active=true
    and csv.status='PUBLISHED'
    and csv.effective_from<=p_scheduled_for_date
    and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
    and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
  limit 1;
  if v_product.customer_id is null then
    raise exception using errcode='P0002', message='This customer is not scheduled for that date.';
  end if;

  -- Something already arrived or was washed: "Nothing sent" would be false.
  if exists(
    select 1
    from public.sorting_trolley_intake_products p
    join public.sorting_trolley_intakes i on i.sorting_trolley_intake_id=p.sorting_trolley_intake_id
    where p.source_schedule_product_id=p_schedule_product_id
      and p.scheduled_for_date=p_scheduled_for_date
      and i.contents_status='CONTENTS'
      and coalesce(i.record_status,'RECORDED')<>'CANCELLED'
  ) or exists(
    select 1 from public.sorting_non_trolley_arrivals a
    where a.source_schedule_product_id=p_schedule_product_id
      and a.scheduled_for_date=p_scheduled_for_date
      and a.status='RECORDED'
  ) or exists(
    select 1
    from public.sorting_wash_run_customers wrc
    join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED'
    where wrc.source_schedule_product_id=p_schedule_product_id
      and wrc.scheduled_for_date=p_scheduled_for_date
  ) then
    raise exception using errcode='22023', message=format('%s already has a receipt or a wash for this date. Nothing sent was not recorded.',v_product.customer_name);
  end if;

  insert into public.sorting_customer_nothing_sent(
    customer_id,customer_name_snapshot,product_code,scheduled_for_date,source_schedule_product_id,
    business_date,shift_id,shift_code_snapshot,operator_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,notes
  ) values (
    v_product.customer_id,v_product.customer_name,v_product.product_code,p_scheduled_for_date,p_schedule_product_id,
    v_business_date,v_shift.shift_id,v_shift.shift_code,p_operator_staff_id,public.current_staff_id(),auth.uid(),
    nullif(trim(coalesce(p_notes,'')),'')
  )
  on conflict (source_schedule_product_id,scheduled_for_date) where status='RECORDED'
  do nothing
  returning * into v_row;

  if v_row.sorting_customer_nothing_sent_id is null then
    return jsonb_build_object('already_recorded',true,'customer_name',v_product.customer_name,
      'message',format('%s was already marked as Nothing sent.',v_product.customer_name));
  end if;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),public.current_staff_id(),'RECORD_SORTING_CUSTOMER_NOTHING_SENT',
    'sorting_customer_nothing_sent',v_row.sorting_customer_nothing_sent_id::text,
    to_jsonb(v_row),v_row.notes,'SORTING_RECEPTION'
  );

  return jsonb_build_object(
    'sorting_customer_nothing_sent_id',v_row.sorting_customer_nothing_sent_id,
    'customer_name',v_product.customer_name,
    'product_code',v_product.product_code,
    'scheduled_for_date',p_scheduled_for_date,
    'message',format('%s marked as Nothing sent.',v_product.customer_name)
  );
end;
$$;

revoke all on function public.record_sorting_customer_nothing_sent(text,uuid,date,uuid,text) from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- Write: undo (cancel) a "Nothing sent" mark. History is kept.
-- ---------------------------------------------------------------------
create or replace function public.cancel_sorting_customer_nothing_sent(
  p_sorting_customer_nothing_sent_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.sorting_customer_nothing_sent%rowtype;
  v_new public.sorting_customer_nothing_sent%rowtype;
begin
  perform public.require_sorting_operational_access();

  select * into v_old
  from public.sorting_customer_nothing_sent
  where sorting_customer_nothing_sent_id=p_sorting_customer_nothing_sent_id
  for update;
  if v_old.sorting_customer_nothing_sent_id is null then
    raise exception using errcode='P0002', message='Nothing sent record was not found.';
  end if;
  if v_old.status<>'RECORDED' then
    return jsonb_build_object('already_cancelled',true,'customer_name',v_old.customer_name_snapshot,
      'message',format('%s is no longer marked as Nothing sent.',v_old.customer_name_snapshot));
  end if;

  update public.sorting_customer_nothing_sent
  set status='CANCELLED',cancelled_at=now(),cancelled_by_auth_user_id=auth.uid(),
      cancellation_reason=coalesce(nullif(trim(coalesce(p_reason,'')),''),'Undone in Sorting.')
  where sorting_customer_nothing_sent_id=v_old.sorting_customer_nothing_sent_id
  returning * into v_new;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
  ) values (
    auth.uid(),public.current_staff_id(),'CANCEL_SORTING_CUSTOMER_NOTHING_SENT',
    'sorting_customer_nothing_sent',v_new.sorting_customer_nothing_sent_id::text,
    to_jsonb(v_old),to_jsonb(v_new),v_new.cancellation_reason,'SORTING_RECEPTION'
  );

  return jsonb_build_object(
    'sorting_customer_nothing_sent_id',v_new.sorting_customer_nothing_sent_id,
    'customer_name',v_new.customer_name_snapshot,
    'message',format('%s is waiting receipt again.',v_new.customer_name_snapshot)
  );
end;
$$;

revoke all on function public.cancel_sorting_customer_nothing_sent(uuid,text) from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- Terminal wrappers: only the registered Sorting computer writes.
-- ---------------------------------------------------------------------
create or replace function public.terminal_record_sorting_customer_nothing_sent(
  p_shift_code text,p_schedule_product_id uuid,p_scheduled_for_date date,p_operator_staff_id uuid,p_notes text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.record_sorting_customer_nothing_sent(p_shift_code,p_schedule_product_id,p_scheduled_for_date,p_operator_staff_id,p_notes);
end; $$;

create or replace function public.terminal_cancel_sorting_customer_nothing_sent(
  p_sorting_customer_nothing_sent_id uuid,p_reason text default null
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('SORTING');
  return public.cancel_sorting_customer_nothing_sent(p_sorting_customer_nothing_sent_id,p_reason);
end; $$;

revoke all on function public.terminal_record_sorting_customer_nothing_sent(text,uuid,date,uuid,text) from public,anon;
revoke all on function public.terminal_cancel_sorting_customer_nothing_sent(uuid,text) from public,anon;
grant execute on function public.terminal_record_sorting_customer_nothing_sent(text,uuid,date,uuid,text) to authenticated;
grant execute on function public.terminal_cancel_sorting_customer_nothing_sent(uuid,text) to authenticated;
