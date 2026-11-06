-- MOP Production: administrator clean-up of the washed MOP queue.
--
-- Problem: staff wash a MOP customer but never enter the processed quantity.
-- The washed Production Flow item then stays in the MOP Production queue for
-- days, and every overdue item also blocks LIVE MOP production
-- ("Resolve N overdue MOP delivery-day confirmation(s)...").
--
-- Solution: an administrator (ADMIN role, or an account with MANAGE on the MOP
-- module; legacy accounts: ADMIN or MANAGER) can clear selected items from the
-- queue with a mandatory reason. Nothing is deleted:
--   * the washing, the Production Flow item and its events stay untouched;
--   * each clearance is a row in sorting_mop_queue_clearances, with who and why;
--   * a clearance can be restored, which puts the item back in the queue;
--   * every clear and restore is written to audit_log.
--
-- Cleared items are excluded from:
--   * get_sorting_mop_production_context (queue and overdue counts);
--   * the "other overdue" check in save_sorting_mop_production.
-- Both functions are patched from their live definition with an exact text
-- replacement that must match once, so the migration fails instead of
-- silently changing something else.

-- 1. Clearance table ---------------------------------------------------------

create table if not exists public.sorting_mop_queue_clearances (
  clearance_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null references public.production_flow_items(production_flow_item_id),
  customer_id uuid,
  customer_name_snapshot text,
  scheduled_for_date date,
  delivery_due_date date,
  washed_kg_total numeric,
  reason text not null,
  cleared_at timestamptz not null default now(),
  cleared_by_staff_id uuid references public.staff_members(staff_id),
  cleared_by_auth_user_id uuid,
  restored_at timestamptz,
  restored_by_staff_id uuid references public.staff_members(staff_id),
  restored_by_auth_user_id uuid,
  restore_reason text,
  constraint sorting_mop_queue_clearances_reason_check check (length(trim(reason)) >= 3),
  constraint sorting_mop_queue_clearances_restore_check check (
    (restored_at is null and restored_by_auth_user_id is null) or restored_at is not null
  )
);

comment on table public.sorting_mop_queue_clearances is
  'Administrator clean-up of the MOP Production queue. An active row (restored_at is null) hides a washed MOP item that never had its production entered. Nothing is deleted; restoring puts the item back in the queue.';

create unique index if not exists sorting_mop_queue_clearances_active_uidx
  on public.sorting_mop_queue_clearances(production_flow_item_id)
  where restored_at is null;

create index if not exists sorting_mop_queue_clearances_cleared_at_idx
  on public.sorting_mop_queue_clearances(cleared_at desc);

alter table public.sorting_mop_queue_clearances enable row level security;
revoke all on table public.sorting_mop_queue_clearances from public, anon, authenticated;

-- 2. Permission --------------------------------------------------------------

create or replace function public.can_clear_sorting_mop_queue()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid() is not null
     and public.current_account_is_enabled()
     and public.account_module_allowed(array['MOP'],'MANAGE',array['ADMIN','MANAGER']);
$$;

revoke all on function public.can_clear_sorting_mop_queue() from public, anon;
grant execute on function public.can_clear_sorting_mop_queue() to authenticated;

create or replace function public.require_sorting_mop_queue_cleanup_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.can_clear_sorting_mop_queue() then
    raise exception using errcode='42501',
      message='Only an administrator can clean up the MOP Production queue.';
  end if;
end;
$$;

revoke all on function public.require_sorting_mop_queue_cleanup_access() from public, anon, authenticated;

-- 3. Clean-up list -----------------------------------------------------------

create or replace function public.get_sorting_mop_queue_cleanup(p_cleared_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_cfg jsonb := public.sorting_mop_reconciliation_config();
  v_local timestamp;
  v_enforcement date;
  v_open jsonb;
  v_cleared jsonb;
begin
  perform public.require_sorting_mop_queue_cleanup_access();
  v_local := now() at time zone coalesce(nullif(v_cfg->>'timezone',''),'Europe/Dublin');
  v_enforcement := coalesce(nullif(v_cfg->>'enforcement_from','')::date, v_local::date);

  select coalesce(jsonb_agg(to_jsonb(q) order by q.delivery_due_date nulls last, lower(q.customer_name)), '[]'::jsonb)
  into v_open
  from (
    select
      pfi.production_flow_item_id,
      pfi.customer_id,
      pfi.customer_name_snapshot as customer_name,
      pfi.scheduled_for_date,
      pfi.opened_business_date,
      public.schedule_delivery_date(pfi.source_schedule_day_id, coalesce(pfi.scheduled_for_date,pfi.opened_business_date)) as delivery_due_date,
      pfi.route_display_name_snapshot as route_display_name,
      pfi.washed_kg_total,
      pfi.last_wash_at,
      (select r.decision from public.sorting_mop_reconciliations r
        where r.production_flow_item_id=pfi.production_flow_item_id
        order by r.recorded_at desc limit 1) as latest_reconciliation_decision
    from public.production_flow_items pfi
    where pfi.product_code='MOP'
      and pfi.flow_status='OPEN'
      and pfi.washed_trace_count>0
      and coalesce(pfi.scheduled_for_date,pfi.opened_business_date)>=v_enforcement
      and not exists(select 1 from public.sorting_mop_production_batches mb
                     where mb.production_flow_item_id=pfi.production_flow_item_id and mb.status='RECORDED')
      and not exists(select 1 from public.sorting_mop_queue_clearances qc
                     where qc.production_flow_item_id=pfi.production_flow_item_id and qc.restored_at is null)
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'clearance_id', c.clearance_id,
    'production_flow_item_id', c.production_flow_item_id,
    'customer_name', c.customer_name_snapshot,
    'scheduled_for_date', c.scheduled_for_date,
    'delivery_due_date', c.delivery_due_date,
    'washed_kg_total', c.washed_kg_total,
    'reason', c.reason,
    'cleared_at', c.cleared_at,
    'cleared_by_name', cs.display_name,
    'restored_at', c.restored_at,
    'restored_by_name', rs.display_name,
    'restore_reason', c.restore_reason,
    'production_recorded_since', exists(select 1 from public.sorting_mop_production_batches mb
                                        where mb.production_flow_item_id=c.production_flow_item_id and mb.status='RECORDED')
  ) order by c.cleared_at desc), '[]'::jsonb)
  into v_cleared
  from (
    select * from public.sorting_mop_queue_clearances
    order by cleared_at desc
    limit least(greatest(coalesce(p_cleared_limit,50),1),200)
  ) c
  left join public.staff_members cs on cs.staff_id=c.cleared_by_staff_id
  left join public.staff_members rs on rs.staff_id=c.restored_by_staff_id;

  return jsonb_build_object(
    'local_date', v_local::date,
    'open_items', v_open,
    'cleared', v_cleared
  );
end;
$$;

revoke all on function public.get_sorting_mop_queue_cleanup(integer) from public, anon;
grant execute on function public.get_sorting_mop_queue_cleanup(integer) to authenticated;

-- 4. Clear selected items ----------------------------------------------------

create or replace function public.clear_sorting_mop_queue_items(p_production_flow_item_ids uuid[], p_reason text)
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
  v_row public.sorting_mop_queue_clearances%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
  v_cleared integer := 0;
  v_skipped jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_mop_queue_cleanup_access();
  if length(v_reason) < 3 then
    raise exception using errcode='22023', message='A short reason is required to clear MOP items.';
  end if;
  if length(v_reason) > 1000 then
    raise exception using errcode='22023', message='The reason must be 1000 characters or fewer.';
  end if;

  select coalesce(array_agg(distinct x), array[]::uuid[]) into v_ids
  from unnest(coalesce(p_production_flow_item_ids, array[]::uuid[])) x where x is not null;
  if cardinality(v_ids) = 0 then
    raise exception using errcode='22023', message='Select at least one MOP customer to clear.';
  end if;
  if cardinality(v_ids) > 500 then
    raise exception using errcode='22023', message='Clear at most 500 MOP customers at a time.';
  end if;

  foreach v_id in array v_ids loop
    select * into v_flow from public.production_flow_items
    where production_flow_item_id = v_id for update;

    if not found or v_flow.product_code <> 'MOP' or v_flow.washed_trace_count <= 0 or v_flow.flow_status <> 'OPEN' then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'reason', 'Not a washed, open MOP item.');
      continue;
    end if;
    if exists(select 1 from public.sorting_mop_production_batches mb
              where mb.production_flow_item_id = v_id and mb.status = 'RECORDED') then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'customer_name', v_flow.customer_name_snapshot, 'reason', 'MOP production is already recorded.');
      continue;
    end if;
    if exists(select 1 from public.sorting_mop_queue_clearances qc
              where qc.production_flow_item_id = v_id and qc.restored_at is null) then
      v_skipped := v_skipped || jsonb_build_object('production_flow_item_id', v_id, 'customer_name', v_flow.customer_name_snapshot, 'reason', 'Already cleared.');
      continue;
    end if;

    insert into public.sorting_mop_queue_clearances(
      production_flow_item_id, customer_id, customer_name_snapshot, scheduled_for_date,
      delivery_due_date, washed_kg_total, reason, cleared_by_staff_id, cleared_by_auth_user_id
    ) values (
      v_flow.production_flow_item_id, v_flow.customer_id, v_flow.customer_name_snapshot, v_flow.scheduled_for_date,
      public.schedule_delivery_date(v_flow.source_schedule_day_id, coalesce(v_flow.scheduled_for_date, v_flow.opened_business_date)),
      v_flow.washed_kg_total, v_reason, v_actor_staff_id, auth.uid()
    ) returning * into v_row;

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
    values (auth.uid(), v_actor_staff_id, 'MOP_QUEUE_ITEM_CLEARED', 'sorting_mop_queue_clearances',
            v_row.clearance_id::text, to_jsonb(v_row), v_reason, 'SORTING_MOP_PRODUCTION');
    v_cleared := v_cleared + 1;
  end loop;

  return jsonb_build_object(
    'cleared_count', v_cleared,
    'skipped', v_skipped,
    'message', format('%s MOP customer(s) cleared from the queue.', v_cleared)
  );
end;
$$;

revoke all on function public.clear_sorting_mop_queue_items(uuid[], text) from public, anon;
grant execute on function public.clear_sorting_mop_queue_items(uuid[], text) to authenticated;

-- 5. Restore a cleared item --------------------------------------------------

create or replace function public.restore_sorting_mop_queue_item(p_clearance_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_row public.sorting_mop_queue_clearances%rowtype;
  v_old jsonb;
  v_actor_staff_id uuid := public.current_staff_id();
begin
  perform public.require_sorting_mop_queue_cleanup_access();

  select * into v_row from public.sorting_mop_queue_clearances
  where clearance_id = p_clearance_id for update;
  if not found then
    raise exception using errcode='P0002', message='MOP clean-up record was not found.';
  end if;
  if v_row.restored_at is not null then
    raise exception using errcode='22023', message='This MOP customer was already restored to the queue.';
  end if;
  v_old := to_jsonb(v_row);

  update public.sorting_mop_queue_clearances
  set restored_at = now(),
      restored_by_staff_id = v_actor_staff_id,
      restored_by_auth_user_id = auth.uid(),
      restore_reason = nullif(left(trim(coalesce(p_reason,'')),1000),'')
  where clearance_id = p_clearance_id
  returning * into v_row;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (auth.uid(), v_actor_staff_id, 'MOP_QUEUE_ITEM_RESTORED', 'sorting_mop_queue_clearances',
          v_row.clearance_id::text, v_old, to_jsonb(v_row), v_row.restore_reason, 'SORTING_MOP_PRODUCTION');

  return jsonb_build_object(
    'clearance_id', v_row.clearance_id,
    'production_flow_item_id', v_row.production_flow_item_id,
    'message', 'MOP customer restored to the queue.'
  );
end;
$$;

revoke all on function public.restore_sorting_mop_queue_item(uuid, text) from public, anon;
grant execute on function public.restore_sorting_mop_queue_item(uuid, text) to authenticated;

-- 6. Exclude cleared items from the queue and from the overdue block ---------

do $migration$
declare
  v_src text;
  v_new text;
  v_needle text;
  v_count integer;
begin
  -- 6a. get_sorting_mop_production_context: hide cleared items, expose the admin flag.
  v_src := pg_get_functiondef('public.get_sorting_mop_production_context(text,timestamptz)'::regprocedure);

  v_needle := '  ), classified as (';
  v_count := (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle);
  if v_count <> 1 then
    raise exception 'get_sorting_mop_production_context: expected 1 "classified as" anchor, found %', v_count;
  end if;
  v_new := replace(v_src, v_needle,
    '      and not exists(select 1 from public.sorting_mop_queue_clearances qc' || chr(10) ||
    '                     where qc.production_flow_item_id=pfi.production_flow_item_id and qc.restored_at is null)' || chr(10) ||
    v_needle);

  v_needle := '''source'',''PRODUCTION_FLOW_WASHED_MOP_PLUS_MOP_PRODUCTION''';
  v_count := (length(v_new) - length(replace(v_new, v_needle, ''))) / length(v_needle);
  if v_count <> 1 then
    raise exception 'get_sorting_mop_production_context: expected 1 source anchor, found %', v_count;
  end if;
  v_new := replace(v_new, v_needle,
    '''can_clear_open_items'',public.can_clear_sorting_mop_queue(),' || chr(10) || '    ' || v_needle);
  execute v_new;

  -- 6b. save_sorting_mop_production: cleared items no longer block LIVE production.
  v_src := pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)'::regprocedure);
  v_needle := 'r.production_flow_item_id=q.production_flow_item_id and r.decision=''NOT_PROCESSED'');';
  v_count := (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle);
  if v_count <> 1 then
    raise exception 'save_sorting_mop_production: expected 1 other-overdue anchor, found %', v_count;
  end if;
  v_new := replace(v_src, v_needle,
    'r.production_flow_item_id=q.production_flow_item_id and r.decision=''NOT_PROCESSED'')' || chr(10) ||
    '    and not exists(select 1 from public.sorting_mop_queue_clearances qc where qc.production_flow_item_id=q.production_flow_item_id and qc.restored_at is null);');
  execute v_new;
end;
$migration$;

-- create or replace keeps the existing grants; restate them for clarity.
revoke all on function public.get_sorting_mop_production_context(text, timestamptz) from public, anon;
grant execute on function public.get_sorting_mop_production_context(text, timestamptz) to authenticated;
revoke all on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text) from public, anon, authenticated;
