-- Finish Production: administrator clean-up of the delivery check.
--
-- Problem: a washed Clothes customer with no Finish production after its
-- delivery deadline opens the "Finish confirmation required" dialog. When staff
-- answer "Not processed" it comes back every two hours, for days, because
-- nobody ever enters the processed quantity.
--
-- Solution (same model as 202611060015 for MOP): an administrator (ADMIN role,
-- or MANAGE on the FINISH module; legacy accounts: ADMIN or MANAGER) can clear
-- selected customers from the delivery check with a mandatory reason.
-- Nothing is deleted:
--   * the wash, the Production Flow item and any earlier delivery-check answer stay;
--   * each clearance is a row in finish_delivery_check_clearances, with who and why;
--   * a clearance can be restored, which brings the customer back to the check;
--   * every clear and restore is written to audit_log.
--
-- get_finish_delivery_reconciliation_context is patched from its live definition
-- with exact text replacements that must match once, so the migration fails
-- instead of silently changing something else.

-- 1. Clearance table ---------------------------------------------------------

create table if not exists public.finish_delivery_check_clearances (
  clearance_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null references public.production_flow_items(production_flow_item_id),
  customer_id uuid,
  customer_name_snapshot text,
  scheduled_for_date date,
  delivery_date date,
  washed_kg_total numeric,
  reason text not null,
  cleared_at timestamptz not null default now(),
  cleared_by_staff_id uuid references public.staff_members(staff_id),
  cleared_by_auth_user_id uuid,
  restored_at timestamptz,
  restored_by_staff_id uuid references public.staff_members(staff_id),
  restored_by_auth_user_id uuid,
  restore_reason text,
  constraint finish_delivery_check_clearances_reason_check check (length(trim(reason)) >= 3)
);

comment on table public.finish_delivery_check_clearances is
  'Administrator clean-up of the Finish delivery check. An active row (restored_at is null) stops a washed Clothes customer with no Finish record from prompting again. Nothing is deleted; restoring brings the customer back to the check.';

create unique index if not exists finish_delivery_check_clearances_active_uidx
  on public.finish_delivery_check_clearances(production_flow_item_id)
  where restored_at is null;

create index if not exists finish_delivery_check_clearances_cleared_at_idx
  on public.finish_delivery_check_clearances(cleared_at desc);

alter table public.finish_delivery_check_clearances enable row level security;
revoke all on table public.finish_delivery_check_clearances from public, anon, authenticated;

-- 2. Permission --------------------------------------------------------------

create or replace function public.can_clear_finish_delivery_check()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid() is not null
     and public.current_account_is_enabled()
     and public.account_module_allowed(array['FINISH'],'MANAGE',array['ADMIN','MANAGER']);
$$;

revoke all on function public.can_clear_finish_delivery_check() from public, anon;
grant execute on function public.can_clear_finish_delivery_check() to authenticated;

create or replace function public.require_finish_delivery_check_cleanup_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.can_clear_finish_delivery_check() then
    raise exception using errcode='42501',
      message='Only an administrator can clean up the Finish delivery check.';
  end if;
end;
$$;

revoke all on function public.require_finish_delivery_check_cleanup_access() from public, anon, authenticated;

-- Shared rule: a washed, open Clothes customer with no Finish production,
-- past its delivery cutoff and not confirmed processed.
create or replace function public.finish_delivery_check_item_open(p_production_flow_item_id uuid, p_at timestamptz default now())
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.production_flow_items pfi
    left join public.finish_delivery_reconciliations rec on rec.production_flow_item_id=pfi.production_flow_item_id
    where pfi.production_flow_item_id=p_production_flow_item_id
      and pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date is not null
      and coalesce(pfi.washed_trace_count,0)>0
      and exists (
        select 1 from public.production_flow_events wash_event
        where wash_event.production_flow_item_id=pfi.production_flow_item_id
          and wash_event.event_type='WASH_RECORDED'
          and left(coalesce(wash_event.source_application,''),4)<>'SIM_'
      )
      and public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date)<=(coalesce(p_at,now()) at time zone 'Europe/Dublin')::date
      and coalesce(p_at,now())>=public.finish_delivery_cutoff(public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date))
      and not exists (
        select 1
        from public.finish_production_entries entry
        join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
        where entry.production_flow_item_id=pfi.production_flow_item_id
          and entry.status='ACTIVE' and line.quantity>0
      )
      and coalesce(rec.outcome_code,'')<>'PROCESSED_CONFIRMED'
  );
$$;

revoke all on function public.finish_delivery_check_item_open(uuid, timestamptz) from public, anon, authenticated;

-- 3. Clean-up list -----------------------------------------------------------

create or replace function public.get_finish_delivery_check_cleanup(p_cleared_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_local_date date := (now() at time zone 'Europe/Dublin')::date;
  v_open jsonb;
  v_cleared jsonb;
begin
  perform public.require_finish_delivery_check_cleanup_access();

  select coalesce(jsonb_agg(to_jsonb(q) order by q.delivery_date, q.scheduled_for_date, lower(q.customer_name)), '[]'::jsonb)
  into v_open
  from (
    select
      pfi.production_flow_item_id,
      pfi.customer_id,
      pfi.customer_name_snapshot as customer_name,
      pfi.scheduled_for_date,
      public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date) as delivery_date,
      greatest(v_local_date-public.schedule_delivery_date(pfi.source_schedule_day_id, pfi.scheduled_for_date),0) as overdue_days,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_name,
      pfi.washed_kg_total,
      rec.outcome_code as previous_outcome_code
    from public.production_flow_items pfi
    left join public.finish_delivery_reconciliations rec on rec.production_flow_item_id=pfi.production_flow_item_id
    where pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date is not null
      and coalesce(pfi.washed_trace_count,0)>0
      and public.finish_delivery_check_item_open(pfi.production_flow_item_id, v_now)
      and not exists(select 1 from public.finish_delivery_check_clearances c
                     where c.production_flow_item_id=pfi.production_flow_item_id and c.restored_at is null)
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'clearance_id', c.clearance_id,
    'production_flow_item_id', c.production_flow_item_id,
    'customer_name', c.customer_name_snapshot,
    'scheduled_for_date', c.scheduled_for_date,
    'delivery_date', c.delivery_date,
    'washed_kg_total', c.washed_kg_total,
    'reason', c.reason,
    'cleared_at', c.cleared_at,
    'cleared_by_name', cs.display_name,
    'restored_at', c.restored_at,
    'restored_by_name', rs.display_name,
    'restore_reason', c.restore_reason,
    'finish_recorded_since', exists(
      select 1 from public.finish_production_entries entry
      join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
      where entry.production_flow_item_id=c.production_flow_item_id and entry.status='ACTIVE' and line.quantity>0)
  ) order by c.cleared_at desc), '[]'::jsonb)
  into v_cleared
  from (
    select * from public.finish_delivery_check_clearances
    order by cleared_at desc
    limit least(greatest(coalesce(p_cleared_limit,50),1),200)
  ) c
  left join public.staff_members cs on cs.staff_id=c.cleared_by_staff_id
  left join public.staff_members rs on rs.staff_id=c.restored_by_staff_id;

  return jsonb_build_object('local_date', v_local_date, 'open_items', v_open, 'cleared', v_cleared);
end;
$$;

revoke all on function public.get_finish_delivery_check_cleanup(integer) from public, anon;
grant execute on function public.get_finish_delivery_check_cleanup(integer) to authenticated;

-- 4. Clear selected customers ------------------------------------------------

create or replace function public.clear_finish_delivery_check_items(p_production_flow_item_ids uuid[], p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_reason text := trim(coalesce(p_reason,''));
  v_ids uuid[];
  v_id uuid;
  v_flow public.production_flow_items%rowtype;
  v_row public.finish_delivery_check_clearances%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
  v_cleared integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  perform public.require_finish_delivery_check_cleanup_access();
  if length(v_reason) < 3 then
    raise exception using errcode='22023', message='A short reason is required to clear Finish customers.';
  end if;
  if length(v_reason) > 1000 then
    raise exception using errcode='22023', message='The reason must be 1000 characters or fewer.';
  end if;

  select coalesce(array_agg(distinct x), array[]::uuid[]) into v_ids
  from unnest(coalesce(p_production_flow_item_ids, array[]::uuid[])) x where x is not null;
  if cardinality(v_ids) = 0 then
    raise exception using errcode='22023', message='Select at least one Finish customer to clear.';
  end if;
  if cardinality(v_ids) > 500 then
    raise exception using errcode='22023', message='Clear at most 500 Finish customers at a time.';
  end if;

  foreach v_id in array v_ids loop
    select * into v_flow from public.production_flow_items
    where production_flow_item_id = v_id for update;

    if not found then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'reason', 'Not found.');
      continue;
    end if;
    if not public.finish_delivery_check_item_open(v_id, now()) then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'customer_name', v_flow.customer_name_snapshot,
        'reason', 'Not waiting for a delivery check (Finish already recorded or confirmed, or not due yet).');
      continue;
    end if;
    if exists(select 1 from public.finish_delivery_check_clearances c
              where c.production_flow_item_id = v_id and c.restored_at is null) then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'customer_name', v_flow.customer_name_snapshot, 'reason', 'Already cleared.');
      continue;
    end if;

    insert into public.finish_delivery_check_clearances(
      production_flow_item_id, customer_id, customer_name_snapshot, scheduled_for_date,
      delivery_date, washed_kg_total, reason, cleared_by_staff_id, cleared_by_auth_user_id
    ) values (
      v_flow.production_flow_item_id, v_flow.customer_id, v_flow.customer_name_snapshot, v_flow.scheduled_for_date,
      public.schedule_delivery_date(v_flow.source_schedule_day_id, v_flow.scheduled_for_date),
      v_flow.washed_kg_total, v_reason, v_actor_staff_id, auth.uid()
    ) returning * into v_row;

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
    values (auth.uid(), v_actor_staff_id, 'FINISH_DELIVERY_CHECK_CLEARED', 'finish_delivery_check_clearances',
            v_row.clearance_id::text, to_jsonb(v_row), v_reason, 'FINISH_DELIVERY_RECONCILIATION');
    v_cleared := v_cleared + 1;
  end loop;

  return jsonb_build_object(
    'cleared_count', v_cleared,
    'skipped', v_skipped,
    'message', format('%s Finish customer(s) cleared from the delivery check.', v_cleared)
  );
end;
$$;

revoke all on function public.clear_finish_delivery_check_items(uuid[], text) from public, anon;
grant execute on function public.clear_finish_delivery_check_items(uuid[], text) to authenticated;

-- 5. Restore a cleared customer ----------------------------------------------

create or replace function public.restore_finish_delivery_check_item(p_clearance_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_row public.finish_delivery_check_clearances%rowtype;
  v_old jsonb;
  v_actor_staff_id uuid := public.current_staff_id();
begin
  perform public.require_finish_delivery_check_cleanup_access();

  select * into v_row from public.finish_delivery_check_clearances
  where clearance_id = p_clearance_id for update;
  if not found then
    raise exception using errcode='P0002', message='Finish clean-up record was not found.';
  end if;
  if v_row.restored_at is not null then
    raise exception using errcode='22023', message='This Finish customer was already restored.';
  end if;
  v_old := to_jsonb(v_row);

  update public.finish_delivery_check_clearances
  set restored_at = now(),
      restored_by_staff_id = v_actor_staff_id,
      restored_by_auth_user_id = auth.uid(),
      restore_reason = nullif(left(trim(coalesce(p_reason,'')),1000),'')
  where clearance_id = p_clearance_id
  returning * into v_row;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (auth.uid(), v_actor_staff_id, 'FINISH_DELIVERY_CHECK_RESTORED', 'finish_delivery_check_clearances',
          v_row.clearance_id::text, v_old, to_jsonb(v_row), v_row.restore_reason, 'FINISH_DELIVERY_RECONCILIATION');

  return jsonb_build_object(
    'clearance_id', v_row.clearance_id,
    'production_flow_item_id', v_row.production_flow_item_id,
    'message', 'Finish customer restored to the delivery check.'
  );
end;
$$;

revoke all on function public.restore_finish_delivery_check_item(uuid, text) from public, anon;
grant execute on function public.restore_finish_delivery_check_item(uuid, text) to authenticated;

-- 6. Cleared customers no longer prompt the delivery check ---------------------

do $migration$
declare
  v_src text;
  v_new text;
  v_needle text;
  v_count integer;
begin
  v_src := pg_get_functiondef('public.get_finish_delivery_reconciliation_context(timestamptz)'::regprocedure);

  v_needle := 'and coalesce(rec.outcome_code,'''')<>''PROCESSED_CONFIRMED''';
  v_count := (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle);
  if v_count <> 1 then
    raise exception 'get_finish_delivery_reconciliation_context: expected 1 outcome anchor, found %', v_count;
  end if;
  v_new := replace(v_src, v_needle,
    v_needle || chr(10) ||
    '      and not exists(select 1 from public.finish_delivery_check_clearances clr' || chr(10) ||
    '                     where clr.production_flow_item_id=pfi.production_flow_item_id and clr.restored_at is null)');

  v_needle := '''pending_count'',jsonb_array_length(v_items),';
  v_count := (length(v_new) - length(replace(v_new, v_needle, ''))) / length(v_needle);
  if v_count <> 1 then
    raise exception 'get_finish_delivery_reconciliation_context: expected 1 pending_count anchor, found %', v_count;
  end if;
  v_new := replace(v_new, v_needle,
    v_needle || chr(10) || '    ''can_clear_open_items'',public.can_clear_finish_delivery_check(),');
  execute v_new;
end;
$migration$;

-- create or replace keeps the existing grants; restate them for clarity.
revoke all on function public.get_finish_delivery_reconciliation_context(timestamptz) from public, anon;
grant execute on function public.get_finish_delivery_reconciliation_context(timestamptz) to authenticated;
