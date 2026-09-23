-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110005_sorting_trolley_kiosk_custody_trace
--
-- The physical trolley lifecycle and the laundry-content/customer flow are
-- related but are NOT the same fact.
--
-- A scanned trolley may:
--   * have a valid tracked stay for the same customer;
--   * have no outbound stay because Finish/MOP missed the trolley;
--   * have a tracked stay for Customer A while the laundry physically being
--     received is confirmed as Customer B (for example trolley/content swap
--     before the Sorting scan).
--
-- Therefore Days at Customer is always attached to the tracked trolley stay,
-- never fabricated from the content/customer confirmation.
-- =====================================================================

begin;

alter table public.sorting_trolley_intakes
  add column if not exists customer_override_code text,
  add column if not exists off_schedule_code text,
  add column if not exists tracked_outbound_customer_id uuid
    references public.customers(customer_id) on delete restrict,
  add column if not exists tracked_outbound_customer_name_snapshot text,
  add column if not exists tracked_sent_on date,
  add column if not exists tracked_days_at_customer integer,
  add column if not exists custody_tracking_status text not null
    default 'MISSING_OUTBOUND_RECORD';

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_customer_override_code_check;
alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_customer_override_code_check
  check (
    customer_override_code is null
    or customer_override_code in (
      'TROLLEY_CHANGED_BEFORE_SCAN',
      'CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT',
      'OTHER'
    )
  );

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_off_schedule_code_check;
alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_off_schedule_code_check
  check (
    off_schedule_code is null
    or off_schedule_code in (
      'SPECIAL_PRODUCTION',
      'SCHEDULE_DATA_ISSUE',
      'NOT_ON_PUBLISHED_SCHEDULE',
      'OTHER'
    )
  );

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_custody_tracking_check;
alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_custody_tracking_check
  check (
    custody_tracking_status in (
      'TRACKED_MATCH',
      'TRACKED_CUSTOMER_MISMATCH',
      'MISSING_OUTBOUND_RECORD'
    )
  );

alter table public.sorting_trolley_intakes
  drop constraint if exists sorting_trolley_intakes_tracked_days_check;
alter table public.sorting_trolley_intakes
  add constraint sorting_trolley_intakes_tracked_days_check
  check (tracked_days_at_customer is null or tracked_days_at_customer >= 0);

create index if not exists sorting_trolley_intakes_custody_tracker_idx
  on public.sorting_trolley_intakes(
    physical_received_on,
    custody_tracking_status,
    tracked_outbound_customer_id,
    tracked_days_at_customer
  );

create or replace function public.get_sorting_trolley_intake_preview_v2(
  p_shift_code text,
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
begin
  perform public.require_sorting_operational_access();

  v_base := public.get_sorting_trolley_intake_preview(p_trolley_code);

  return v_base || jsonb_build_object(
    'business_date',v_business_date,
    'physical_received_on',current_date,
    'shift_code',upper(trim(coalesce(p_shift_code,''))),
    'custody',case
      when v_base->'current_stay' is not null
       and jsonb_typeof(v_base->'current_stay')='object'
       and nullif(v_base->'current_stay'->>'stay_id','') is not null
      then jsonb_build_object(
        'tracking_status','TRACKED',
        'stay_id',v_base->'current_stay'->>'stay_id',
        'customer_id',v_base->'current_stay'->>'outbound_customer_id',
        'customer_name',v_base->'current_stay'->>'customer_name',
        'sent_on',v_base->'current_stay'->>'sent_on',
        'days_at_customer',v_base->'current_stay'->'days_out'
      )
      else jsonb_build_object(
        'tracking_status','MISSING_OUTBOUND_RECORD',
        'stay_id',null,
        'customer_id',null,
        'customer_name',null,
        'sent_on',null,
        'days_at_customer',null
      )
    end,
    'trolley_becomes_available_after_confirmation',true
  );
end;
$$;

create or replace function public.record_sorting_trolley_intake_v2(
  p_shift_code text,
  p_trolley_code text,
  p_operator_staff_id uuid,
  p_customer_id uuid,
  p_contents_status text,
  p_scheduled_for_date date,
  p_product_codes text[],
  p_customer_override_reason text default null,
  p_off_schedule_reason text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_code text := upper(trim(coalesce(p_trolley_code,'')));
  v_contents text := upper(trim(coalesce(p_contents_status,'')));
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_trolley public.trolleys%rowtype;
  v_customer public.customers%rowtype;
  v_suggestion record;
  v_confirmation_source text := 'MANUAL_SELECTION';
  v_customer_override_reason text := nullif(trim(coalesce(p_customer_override_reason,'')),'');
  v_off_schedule_reason text := nullif(trim(coalesce(p_off_schedule_reason,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_products text[];
  v_product text;
  v_product_scope text;
  v_relation text;
  v_receipt jsonb;
  v_stay_id uuid;
  v_intake public.sorting_trolley_intakes%rowtype;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_schedule_product_id uuid;
  v_production_order integer;
  v_planned_trolley_quantity integer;
  v_route_id uuid;
  v_route_code text;
  v_route_display_name text;
  v_route_color text;
  v_flow_id uuid;
  v_child_id uuid;
  v_actor_staff_id uuid := public.current_staff_id();
  v_attendance_inserted integer := 0;
  v_product_payload jsonb := '[]'::jsonb;
  v_tracked_stay_id uuid;
  v_tracked_customer_id uuid;
  v_tracked_customer_name text;
  v_tracked_sent_on date;
  v_tracked_days integer;
  v_custody_tracking_status text := 'MISSING_OUTBOUND_RECORD';
  v_customer_override_code text;
  v_off_schedule_code text;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  if v_code='' then
    raise exception using errcode='22023', message='Trolley code is required.';
  end if;

  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Select your name before receiving the trolley.';
  end if;

  if p_customer_id is null then
    raise exception using errcode='22023', message='Confirmed customer is required.';
  end if;

  if v_contents not in ('CONTENTS','EMPTY') then
    raise exception using errcode='22023', message='Choose Laundry inside or Empty trolley.';
  end if;

  if exists(
    select 1
    from unnest(coalesce(p_product_codes,array[]::text[])) x
    where upper(trim(x)) not in ('CLOTHES','MOP')
  ) then
    raise exception using errcode='22023', message='Product selection contains an invalid value.';
  end if;

  select array_agg(distinct upper(trim(x)) order by upper(trim(x)))
  into v_products
  from unnest(coalesce(p_product_codes,array[]::text[])) x
  where upper(trim(x)) in ('CLOTHES','MOP');

  if coalesce(array_length(v_products,1),0)=0
     or array_length(v_products,1)>2 then
    raise exception using errcode='22023', message='Choose Clothes, MOP or Both.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='Trolley intake notes must be 1000 characters or fewer.';
  end if;

  if v_customer_override_reason is not null and length(v_customer_override_reason)>500 then
    raise exception using errcode='22023', message='Customer override reason must be 500 characters or fewer.';
  end if;

  if v_off_schedule_reason is not null and length(v_off_schedule_reason)>500 then
    raise exception using errcode='22023', message='Off-schedule reason must be 500 characters or fewer.';
  end if;

  v_customer_override_code := case upper(coalesce(v_customer_override_reason,''))
    when 'TROLLEY_CHANGED_BEFORE_SCAN' then 'TROLLEY_CHANGED_BEFORE_SCAN'
    when 'CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT' then 'CONTENTS_CUSTOMER_CONFIRMED_DIFFERENT'
    when 'OTHER' then 'OTHER'
    when '' then null
    else 'OTHER'
  end;

  v_off_schedule_code := case upper(coalesce(v_off_schedule_reason,''))
    when 'SPECIAL_PRODUCTION' then 'SPECIAL_PRODUCTION'
    when 'SCHEDULE_DATA_ISSUE' then 'SCHEDULE_DATA_ISSUE'
    when 'NOT_ON_PUBLISHED_SCHEDULE' then 'NOT_ON_PUBLISHED_SCHEDULE'
    when 'OTHER' then 'OTHER'
    when '' then null
    else 'OTHER'
  end;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code=v_shift_code
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  -- Operator must be an Actual/Planned Sorting staff candidate for the shift.
  if not exists (
    select 1
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift_code)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id'=p_operator_staff_id::text
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is not active in Sorting for this shift.';
  end if;

  if exists (
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
      and a.attendance_status='ABSENT'
  ) then
    raise exception using
      errcode='22023',
      message='Selected staff member is marked absent. Correct attendance before receiving a trolley.';
  end if;

  select *
  into v_trolley
  from public.trolleys t
  where lower(t.trolley_code)=lower(v_code)
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode='P0002', message=format('Trolley not found: %s',v_code);
  end if;

  if v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
    raise exception using
      errcode='23514',
      message=format('Trolley %s cannot be received while status is %s.',v_code,v_trolley.status);
  end if;

  if exists (
    select 1
    from public.sorting_trolley_intakes sti
    where sti.trolley_id=v_trolley.trolley_id
      and sti.created_at>=now()-interval '10 minutes'
  ) then
    raise exception using
      errcode='23505',
      message=format('Trolley %s was already received a few minutes ago.',v_code);
  end if;

  select *
  into v_customer
  from public.customers c
  where c.customer_id=p_customer_id
    and c.active=true
    and c.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='22023', message='Confirmed customer is not active.';
  end if;

  select *
  into v_suggestion
  from public.suggest_trolley_customer(v_code);

  if v_suggestion.open_stay_id is not null then
    v_confirmation_source := 'OPEN_STAY';
  elsif v_suggestion.suggested_customer_id=p_customer_id
        and coalesce(v_suggestion.suggestion_reason,'')='LAST_KNOWN_CUSTOMER' then
    v_confirmation_source := 'LAST_KNOWN_CUSTOMER';
  else
    v_confirmation_source := 'MANUAL_SELECTION';
  end if;

  if v_suggestion.suggested_customer_id is not null
     and v_suggestion.suggested_customer_id is distinct from p_customer_id
     and v_customer_override_reason is null then
    raise exception using
      errcode='22023',
      message='Customer differs from trolley history. Enter the reason before confirming.';
  end if;

  if p_scheduled_for_date is null then
    if v_off_schedule_reason is null then
      raise exception using
        errcode='22023',
        message='Off-schedule trolley intake requires a reason.';
    end if;
    v_relation := 'OFF_SCHEDULE';
  else
    if p_scheduled_for_date < v_business_date-1
       or p_scheduled_for_date > v_business_date+1 then
      raise exception using
        errcode='22023',
        message='Scheduled Date must be Yesterday, Today or Tomorrow for Sorting Intake.';
    end if;

    v_relation := case
      when p_scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      when p_scheduled_for_date=v_business_date then 'TODAY'
      else 'TOMORROW'
    end;
    v_off_schedule_reason := null;
  end if;

  -- Validate every selected product before closing physical custody.
  foreach v_product in array v_products loop
    if p_scheduled_for_date is not null then
      perform 1
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
      where csv.customer_id=p_customer_id
        and csv.status='PUBLISHED'
        and csv.effective_from<=p_scheduled_for_date
        and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
        and pt.product_code=v_product;

      if not found then
        raise exception using
          errcode='22023',
          message=format(
            '%s is not published for %s on %s. Choose the correct Scheduled Date or use Off schedule with a reason.',
            v_product,v_customer.customer_name,p_scheduled_for_date
          );
      end if;
    end if;
  end loop;

  -- Snapshot the tracked physical stay BEFORE receipt closes it.
  -- This is deliberately separate from the customer/content confirmation.
  select
    s.stay_id,
    s.outbound_customer_id,
    c.customer_name,
    s.sent_on,
    case
      when s.sent_on is null or current_date < s.sent_on then null
      else current_date - s.sent_on
    end
  into
    v_tracked_stay_id,
    v_tracked_customer_id,
    v_tracked_customer_name,
    v_tracked_sent_on,
    v_tracked_days
  from public.trolley_customer_stays s
  left join public.customers c
    on c.customer_id=s.outbound_customer_id
  where s.trolley_id=v_trolley.trolley_id
    and s.received_on is null
  order by s.created_at desc
  limit 1;

  v_custody_tracking_status := case
    when v_tracked_stay_id is null then 'MISSING_OUTBOUND_RECORD'
    when v_tracked_customer_id is distinct from p_customer_id then 'TRACKED_CUSTOMER_MISMATCH'
    else 'TRACKED_MATCH'
  end;

  -- Physical custody uses the actual calendar day. Operational grouping is
  -- preserved separately in sorting_trolley_intakes.business_date.
  v_receipt := public.confirm_trolley_sorting_arrival(
    p_trolley_code=>v_code,
    p_customer_id=>p_customer_id,
    p_arrived_on=>current_date,
    p_confirmation_source=>v_confirmation_source,
    p_notes=>v_notes
  );

  v_stay_id := nullif(v_receipt->>'stay_id','')::uuid;

  if v_stay_id is null then
    raise exception using errcode='P0001', message='Trolley lifecycle receipt did not return a stay ID.';
  end if;

  v_product_scope := case
    when array_length(v_products,1)=2 then 'BOTH'
    else v_products[1]
  end;

  insert into public.sorting_trolley_intakes(
    stay_id,trolley_id,trolley_code_snapshot,
    customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,physical_received_on,shift_id,shift_code_snapshot,arrived_at,
    contents_status,product_scope,scheduled_for_date,schedule_relation,
    confirmation_source,suggestion_reason,suggested_customer_id,
    customer_override_reason,off_schedule_reason,
    customer_override_code,off_schedule_code,
    tracked_outbound_customer_id,tracked_outbound_customer_name_snapshot,
    tracked_sent_on,tracked_days_at_customer,custody_tracking_status,
    exception_type,review_status,
    operator_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,
    notes
  )
  values(
    v_stay_id,v_trolley.trolley_id,v_code,
    v_customer.customer_id,v_customer.customer_code,v_customer.customer_name,
    v_business_date,current_date,v_shift.shift_id,v_shift_code,now(),
    v_contents,v_product_scope,p_scheduled_for_date,v_relation,
    v_confirmation_source,v_suggestion.suggestion_reason,v_suggestion.suggested_customer_id,
    v_customer_override_reason,v_off_schedule_reason,
    v_customer_override_code,v_off_schedule_code,
    v_tracked_customer_id,v_tracked_customer_name,
    v_tracked_sent_on,v_tracked_days,v_custody_tracking_status,
    nullif(v_receipt->>'exception_type',''),coalesce(v_receipt->>'review_status','NOT_REQUIRED'),
    p_operator_staff_id,v_actor_staff_id,auth.uid(),
    v_notes
  )
  returning * into v_intake;

  foreach v_product in array v_products loop
    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_schedule_product_id := null;
    v_production_order := null;
    v_planned_trolley_quantity := null;
    v_route_id := null;
    v_route_code := null;
    v_route_display_name := null;
    v_route_color := null;

    if p_scheduled_for_date is not null then
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
        r.display_name as route_display_name,
        r.route_color
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_schedule_product_id,
        v_production_order,
        v_planned_trolley_quantity,
        v_route_id,
        v_route_code,
        v_route_display_name,
        v_route_color
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
    end if;

    v_flow_id := public.ensure_production_flow_item(
      p_customer_id,
      v_product,
      p_scheduled_for_date,
      v_business_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color
    );

    insert into public.sorting_trolley_intake_products(
      sorting_trolley_intake_id,
      product_code,
      scheduled_for_date,
      source_schedule_version_id,
      source_schedule_day_id,
      source_schedule_product_id,
      production_order_snapshot,
      planned_trolley_quantity_snapshot,
      route_id_snapshot,
      route_code_snapshot,
      route_display_name_snapshot,
      route_color_snapshot,
      production_flow_item_id
    )
    values(
      v_intake.sorting_trolley_intake_id,
      v_product,
      p_scheduled_for_date,
      v_schedule_version_id,
      v_schedule_day_id,
      v_schedule_product_id,
      v_production_order,
      v_planned_trolley_quantity,
      v_route_id,
      v_route_code,
      v_route_display_name,
      v_route_color,
      v_flow_id
    )
    returning sorting_trolley_intake_product_id into v_child_id;

    perform public.append_production_flow_event(
      v_flow_id,
      case when v_contents='CONTENTS' then 'TROLLEY_RECEIVED_CONTENTS' else 'TROLLEY_RECEIVED_EMPTY' end,
      'INTAKE',
      20,
      'SORTING',
      v_business_date,
      v_intake.arrived_at,
      p_operator_staff_id,
      v_actor_staff_id,
      auth.uid(),
      'SORTING_V2',
      'sorting_trolley_intake_products',
      v_child_id::text,
      jsonb_build_object(
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
        'stay_id',v_stay_id,
        'trolley_id',v_trolley.trolley_id,
        'trolley_code',v_code,
        'customer_id',p_customer_id,
        'customer_name',v_customer.customer_name,
        'contents_status',v_contents,
        'product_code',v_product,
        'scheduled_for_date',p_scheduled_for_date,
        'schedule_relation',v_relation,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code,
        'review_status',v_intake.review_status,
        'exception_type',v_intake.exception_type,
        'physical_received_on',current_date,
        'custody_tracking_status',v_custody_tracking_status,
        'tracked_outbound_customer_id',v_tracked_customer_id,
        'tracked_outbound_customer_name',v_tracked_customer_name,
        'tracked_sent_on',v_tracked_sent_on,
        'tracked_days_at_customer',v_tracked_days,
        'customer_override_code',v_customer_override_code,
        'off_schedule_code',v_off_schedule_code,
        'trolley_status_after_receipt','AVAILABLE'
      )
    );

    v_product_payload := v_product_payload || jsonb_build_array(
      jsonb_build_object(
        'product_code',v_product,
        'production_flow_item_id',v_flow_id,
        'planned_trolley_quantity',
          v_planned_trolley_quantity,
        'route_code',
          v_route_code
      )
    );
  end loop;

  insert into public.trolley_events(
    trolley_id,stay_id,event_type,customer_id,business_date,
    performed_by,source_application,reason,metadata
  )
  values(
    v_trolley.trolley_id,
    v_stay_id,
    case when v_contents='CONTENTS'
      then 'SORTING_CONTENTS_CONFIRMED'
      else 'SORTING_EMPTY_CONFIRMED'
    end,
    p_customer_id,
    v_business_date,
    p_operator_staff_id,
    'SORTING_V2',
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    jsonb_build_object(
      'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
      'contents_status',v_contents,
      'product_scope',v_product_scope,
      'product_codes',to_jsonb(v_products),
      'scheduled_for_date',p_scheduled_for_date,
      'schedule_relation',v_relation,
      'physical_received_on',current_date,
      'recorded_by_staff_id',v_actor_staff_id,
      'custody_tracking_status',v_custody_tracking_status,
      'tracked_outbound_customer_id',v_tracked_customer_id,
      'tracked_outbound_customer_name',v_tracked_customer_name,
      'tracked_sent_on',v_tracked_sent_on,
      'tracked_days_at_customer',v_tracked_days,
      'customer_override_code',v_customer_override_code,
      'off_schedule_code',v_off_schedule_code,
      'trolley_status_after_receipt','AVAILABLE'
    )
  );

  -- Trolley Intake is real presence evidence. Do not leave a staff member as
  -- inferred AUTO_ABSENT after they physically record an intake.
  insert into public.sorting_daily_staff_attendance(
    business_date,shift_id,staff_id,
    attendance_status,absence_reason,notes,source,
    created_by_auth_user_id,updated_by_auth_user_id
  )
  select
    v_business_date,v_shift.shift_id,p_operator_staff_id,
    'PRESENT',null,
    'Presence evidence from Sorting Trolley Intake ' || v_code || '.',
    'SORTING_TROLLEY_INTAKE',
    auth.uid(),auth.uid()
  where not exists(
    select 1
    from public.sorting_daily_staff_attendance a
    where a.business_date=v_business_date
      and a.shift_id=v_shift.shift_id
      and a.staff_id=p_operator_staff_id
  );

  get diagnostics v_attendance_inserted = row_count;

  if v_attendance_inserted>0 then
    insert into public.audit_log(
      actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
      new_data,reason,source_application
    )
    values(
      auth.uid(),v_actor_staff_id,
      'SORTING_ATTENDANCE_EVIDENCE_TROLLEY_INTAKE',
      'sorting_daily_staff_attendance',
      p_operator_staff_id::text || ':' || v_business_date::text || ':' || v_shift.shift_id::text,
      jsonb_build_object(
        'business_date',v_business_date,
        'shift_code',v_shift_code,
        'staff_id',p_operator_staff_id,
        'evidence','TROLLEY_INTAKE',
        'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id
      ),
      'Physical trolley intake recorded.',
      'SORTING_V2'
    );
  end if;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    new_data,reason,source_application
  )
  values(
    auth.uid(),v_actor_staff_id,
    case when v_contents='CONTENTS'
      then 'SORTING_TROLLEY_CONTENTS_INTAKE_RECORDED'
      else 'SORTING_TROLLEY_EMPTY_INTAKE_RECORDED'
    end,
    'sorting_trolley_intakes',
    v_intake.sorting_trolley_intake_id::text,
    to_jsonb(v_intake) || jsonb_build_object('products',v_product_payload),
    coalesce(v_customer_override_reason,v_off_schedule_reason,v_notes),
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status','success',
    'sorting_trolley_intake_id',v_intake.sorting_trolley_intake_id,
    'stay_id',v_stay_id,
    'trolley_code',v_code,
    'customer_id',p_customer_id,
    'customer_name',v_customer.customer_name,
    'business_date',v_business_date,
    'physical_received_on',current_date,
    'contents_status',v_contents,
    'product_scope',v_product_scope,
    'scheduled_for_date',p_scheduled_for_date,
    'schedule_relation',v_relation,
    'review_status',v_intake.review_status,
    'products',v_product_payload,
    'custody_tracking_status',v_custody_tracking_status,
    'tracked_outbound_customer_id',v_tracked_customer_id,
    'tracked_outbound_customer_name',v_tracked_customer_name,
    'tracked_sent_on',v_tracked_sent_on,
    'tracked_days_at_customer',v_tracked_days,
    'trolley_status_after_receipt','AVAILABLE',
    'message',case
      when v_intake.review_status in ('PENDING','UNDER_REVIEW')
        then format('%s received. Trolley history needs review.',v_code)
      when v_contents='EMPTY'
        then format('%s received empty. No wash record was created.',v_code)
      else format('%s received with laundry. Customer is now visible in the wash queue.',v_code)
    end
  );
end;
$$;


-- Keep the source table private. Browser access remains RPC-only.
revoke all on table public.sorting_trolley_intakes
  from public, anon, authenticated;

revoke all on function public.get_sorting_trolley_intake_preview_v2(text,text)
  from public, anon, authenticated;
revoke all on function public.record_sorting_trolley_intake_v2(
  text,text,uuid,uuid,text,date,text[],text,text,text
) from public, anon, authenticated;

grant execute on function public.get_sorting_trolley_intake_preview_v2(text,text)
  to authenticated;
grant execute on function public.record_sorting_trolley_intake_v2(
  text,text,uuid,uuid,text,date,text[],text,text,text
) to authenticated;

comment on column public.sorting_trolley_intakes.tracked_days_at_customer is
  'Evidence-based days out for the scanned physical trolley, derived only from its pre-existing open stay sent_on to physical receipt date. Null when no outbound stay exists.';

comment on column public.sorting_trolley_intakes.custody_tracking_status is
  'Separates physical trolley custody evidence from the customer/content confirmation. TRACKED_CUSTOMER_MISMATCH means Days out belongs to the tracked outbound customer, not the confirmed contents customer.';

comment on function public.get_sorting_trolley_intake_preview_v2(text,text) is
  'Touch-kiosk preview including explicit tracked trolley custody customer, sent date, Days at Customer and the fact that confirmation releases the trolley to AVAILABLE.';

commit;
