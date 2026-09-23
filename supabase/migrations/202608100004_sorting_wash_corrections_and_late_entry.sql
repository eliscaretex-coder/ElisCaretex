-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100004_sorting_wash_corrections_and_late_entry.sql
--
-- Operational correction model:
--   * original Wash ID is never rewritten into a different reality;
--   * correction atomically CANCELS the original and creates a replacement Wash ID;
--   * cancellation keeps the original record and audit history;
--   * missed recording creates a normal RECORDED Wash ID marked LATE_ENTRY;
--   * only RECORDED washes count toward the customer washing board.
--
-- Trolley intake remains the next phase. EMPTY trolley receipt must later close
-- the expected-to-wash flow without fabricating a zero-KG wash.
-- =====================================================================

begin;

alter table public.sorting_wash_runs
  add column if not exists entry_mode text not null default 'LIVE',
  add column if not exists replaces_wash_run_id uuid
    references public.sorting_wash_runs(wash_run_id) on delete restrict,
  add column if not exists correction_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by_auth_user_id uuid
    references auth.users(id) on delete set null,
  add column if not exists cancellation_reason text;

alter table public.sorting_wash_runs
  drop constraint if exists sorting_wash_runs_entry_mode_check;
alter table public.sorting_wash_runs
  add constraint sorting_wash_runs_entry_mode_check
    check (entry_mode in ('LIVE','LATE_ENTRY','CORRECTION'));

create index if not exists sorting_wash_runs_replaces_idx
  on public.sorting_wash_runs(replaces_wash_run_id)
  where replaces_wash_run_id is not null;

-- ---------------------------------------------------------------------
-- 1. Recent context V3: active + cancelled history and correction linkage
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_washing_context_v3(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_base jsonb;
  v_recent_washes jsonb := '[]'::jsonb;
begin
  v_base := public.get_sorting_washing_context_v2(p_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id', q.wash_run_id,
      'wash_code', q.wash_code,
      'business_date', q.business_date,
      'shift_code', q.shift_code_snapshot,
      'washer_id', q.washer_id,
      'washer_code', q.washer_code_snapshot,
      'washer_name', q.washer_name_snapshot,
      'operator_staff_id', q.operator_staff_id,
      'operator_name', q.operator_name_snapshot,
      'wash_type', q.wash_type,
      'started_at', q.started_at,
      'registered_at', q.registered_at,
      'total_weight_kg', q.total_weight_kg,
      'status', q.status,
      'entry_mode', q.entry_mode,
      'row_version', q.row_version,
      'notes', q.notes,
      'correction_reason', q.correction_reason,
      'cancellation_reason', q.cancellation_reason,
      'cancelled_at', q.cancelled_at,
      'replaces_wash_run_id', q.replaces_wash_run_id,
      'replaces_wash_code', replaced.wash_code,
      'replacement_wash_code', replacement.wash_code,
      'customers', q.customers
    )
    order by q.business_date desc, q.started_at desc, q.registered_at desc
  ), '[]'::jsonb)
  into v_recent_washes
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id', wrc.wash_run_customer_id,
            'trace_code', wrc.trace_code,
            'customer_id', wrc.customer_id,
            'customer_code', wrc.customer_code_snapshot,
            'customer_name', wrc.customer_name_snapshot,
            'schedule_product_id', wrc.source_schedule_product_id,
            'schedule_relation', wrc.schedule_relation,
            'scheduled_for_date', wrc.scheduled_for_date,
            'scheduled_weekday',
              coalesce(
                wrc.scheduled_weekday_name_snapshot,
                case
                  when wrc.scheduled_for_date is null then null
                  else trim(to_char(wrc.scheduled_for_date, 'Day'))
                end
              ),
            'route_code',
              coalesce(nullif(wrc.route_code_snapshot, ''), r.route_code),
            'route_display_name',
              coalesce(nullif(wrc.route_display_name_snapshot, ''), r.display_name),
            'route_color',
              coalesce(nullif(wrc.route_color_snapshot, ''), r.route_color)
          )
          order by lower(wrc.customer_name_snapshot), wrc.trace_code
        )
        from public.sorting_wash_run_customers wrc
        left join public.customer_schedule_products sp
          on sp.schedule_product_id = wrc.source_schedule_product_id
        left join public.customer_schedule_days sd
          on sd.schedule_day_id = sp.schedule_day_id
        left join public.distribution_routes r
          on r.route_id = sd.default_route_id
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) as customers
    from public.sorting_wash_runs wr
    where wr.business_date between (v_business_date - 2) and v_business_date
    order by wr.business_date desc, wr.started_at desc, wr.registered_at desc
    limit 100
  ) q
  left join public.sorting_wash_runs replaced
    on replaced.wash_run_id = q.replaces_wash_run_id
  left join lateral (
    select child.wash_code
    from public.sorting_wash_runs child
    where child.replaces_wash_run_id = q.wash_run_id
    order by child.created_at desc
    limit 1
  ) replacement on true;

  return v_base || jsonb_build_object(
    'recent_washes', v_recent_washes,
    'recent_wash_window_days', 3,
    'corrections_supported', true,
    'late_entry_supported', true
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Cancel a wrong wash record (logical delete)
-- ---------------------------------------------------------------------

create or replace function public.cancel_sorting_wash_run(
  p_wash_run_id uuid,
  p_expected_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_old public.sorting_wash_runs%rowtype;
  v_new public.sorting_wash_runs%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  perform public.require_sorting_operational_access();

  if p_wash_run_id is null then
    raise exception using errcode='22023', message='Wash record is required.';
  end if;
  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required to cancel a washing record.';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Cancellation reason must be 500 characters or fewer.';
  end if;

  select *
  into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  if v_old.status <> 'RECORDED' then
    raise exception using errcode='22023', message='Only an active RECORDED washing can be cancelled.';
  end if;

  if v_old.business_date <> v_business_date then
    raise exception using
      errcode='22023',
      message='Sorting operators can cancel only today''s washing records. Older records require management review.';
  end if;

  if p_expected_row_version is null or p_expected_row_version <> v_old.row_version then
    raise exception using
      errcode='40001',
      message='This washing record changed after it was loaded. Reload before cancelling.';
  end if;

  update public.sorting_wash_runs
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancelled_by_auth_user_id = auth.uid(),
      cancellation_reason = v_reason,
      updated_at = now(),
      row_version = row_version + 1,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'cancelled_from', 'SORTING_V2',
        'cancelled_at', now()
      )
  where wash_run_id = p_wash_run_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SORTING_WASH_CANCELLED',
    'sorting_wash_runs',
    v_old.wash_run_id::text,
    to_jsonb(v_old),
    to_jsonb(v_new),
    v_reason,
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status','success',
    'wash_run_id',v_new.wash_run_id,
    'wash_code',v_new.wash_code,
    'row_version',v_new.row_version,
    'message',format('%s cancelled. It no longer counts as a completed wash.',v_new.wash_code)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Correction = cancel old + create replacement atomically
-- ---------------------------------------------------------------------

create or replace function public.correct_sorting_wash_run_v2(
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
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_old public.sorting_wash_runs%rowtype;
  v_cancelled public.sorting_wash_runs%rowtype;
  v_new public.sorting_wash_runs%rowtype;
  v_result jsonb;
  v_new_id uuid;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  perform public.require_sorting_operational_access();

  if v_reason is null then
    raise exception using errcode='22023', message='Correction reason is required.';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Correction reason must be 500 characters or fewer.';
  end if;

  select *
  into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  if v_old.status <> 'RECORDED' then
    raise exception using errcode='22023', message='Only an active RECORDED washing can be corrected.';
  end if;

  if v_old.business_date <> v_business_date then
    raise exception using
      errcode='22023',
      message='Sorting operators can correct only today''s washing records. Older records require management review.';
  end if;

  if p_expected_row_version is null or p_expected_row_version <> v_old.row_version then
    raise exception using
      errcode='40001',
      message='This washing record changed after it was loaded. Reload before correcting.';
  end if;

  -- Cancel inside the same transaction. If replacement creation fails, this
  -- cancellation also rolls back automatically.
  update public.sorting_wash_runs
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancelled_by_auth_user_id = auth.uid(),
      cancellation_reason = 'Corrected: ' || v_reason,
      updated_at = now(),
      row_version = row_version + 1,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'cancelled_for_correction', true,
        'correction_reason', v_reason
      )
  where wash_run_id = v_old.wash_run_id
  returning * into v_cancelled;

  v_result := public.save_sorting_wash_run_v2(
    p_shift_code => p_shift_code,
    p_washer_id => p_washer_id,
    p_operator_staff_id => p_operator_staff_id,
    p_start_time => p_start_time,
    p_weight_kg => p_weight_kg,
    p_wash_type => p_wash_type,
    p_customer_selections => p_customer_selections,
    p_notes => p_notes
  );

  v_new_id := nullif(v_result ->> 'wash_run_id','')::uuid;

  update public.sorting_wash_runs
  set entry_mode = 'CORRECTION',
      replaces_wash_run_id = v_old.wash_run_id,
      correction_reason = v_reason,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'corrects_wash_code', v_old.wash_code,
        'correction_reason', v_reason
      ),
      updated_at = now(),
      row_version = row_version + 1
  where wash_run_id = v_new_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application, correlation_id
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SORTING_WASH_CORRECTED',
    'sorting_wash_runs',
    v_new.wash_run_id::text,
    to_jsonb(v_old),
    to_jsonb(v_new),
    v_reason,
    'SORTING_V2',
    v_old.wash_run_id
  );

  return v_result || jsonb_build_object(
    'status','success',
    'wash_run_id',v_new.wash_run_id,
    'wash_code',v_new.wash_code,
    'row_version',v_new.row_version,
    'entry_mode','CORRECTION',
    'replaces_wash_run_id',v_old.wash_run_id,
    'replaces_wash_code',v_old.wash_code,
    'message',format('%s corrected. Replacement Wash ID: %s.',v_old.wash_code,v_new.wash_code)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Missed recording / late entry
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_missed_wash_v2(
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
  v_result jsonb;
  v_new public.sorting_wash_runs%rowtype;
  v_id uuid;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  perform public.require_sorting_operational_access();

  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required for a missed wash entry.';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Late-entry reason must be 500 characters or fewer.';
  end if;

  v_result := public.save_sorting_wash_run_v2(
    p_shift_code => p_shift_code,
    p_washer_id => p_washer_id,
    p_operator_staff_id => p_operator_staff_id,
    p_start_time => p_start_time,
    p_weight_kg => p_weight_kg,
    p_wash_type => p_wash_type,
    p_customer_selections => p_customer_selections,
    p_notes => p_notes
  );

  v_id := nullif(v_result ->> 'wash_run_id','')::uuid;

  update public.sorting_wash_runs
  set entry_mode = 'LATE_ENTRY',
      correction_reason = v_reason,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'late_entry', true,
        'late_entry_reason', v_reason,
        'registered_after_wash', true
      ),
      updated_at = now(),
      row_version = row_version + 1
  where wash_run_id = v_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SORTING_WASH_LATE_ENTRY',
    'sorting_wash_runs',
    v_new.wash_run_id::text,
    to_jsonb(v_new),
    v_reason,
    'SORTING_V2'
  );

  return v_result || jsonb_build_object(
    'status','success',
    'wash_run_id',v_new.wash_run_id,
    'wash_code',v_new.wash_code,
    'row_version',v_new.row_version,
    'entry_mode','LATE_ENTRY',
    'message',format('Missed wash recorded as %s (Late entry).',v_new.wash_code)
  );
end;
$$;

revoke all on function public.get_sorting_washing_context_v3(text)
  from public, anon, authenticated;
revoke all on function public.cancel_sorting_wash_run(uuid,integer,text)
  from public, anon, authenticated;
revoke all on function public.correct_sorting_wash_run_v2(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_missed_wash_v2(text,uuid,uuid,time,numeric,text,jsonb,text,text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_washing_context_v3(text)
  to authenticated;
grant execute on function public.cancel_sorting_wash_run(uuid,integer,text)
  to authenticated;
grant execute on function public.correct_sorting_wash_run_v2(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text)
  to authenticated;
grant execute on function public.save_sorting_missed_wash_v2(text,uuid,uuid,time,numeric,text,jsonb,text,text)
  to authenticated;

comment on function public.correct_sorting_wash_run_v2(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text) is
  'Atomically cancels an incorrect current-day Wash ID and creates a replacement Wash ID with corrected washer/operator/type/KG/customer schedule selections. Original data remains immutable evidence.';

comment on function public.save_sorting_missed_wash_v2(text,uuid,uuid,time,numeric,text,jsonb,text,text) is
  'Records a wash that physically happened but was not entered at the time. started_at is the physical wash time; registered_at remains the later system entry time.';

commit;
