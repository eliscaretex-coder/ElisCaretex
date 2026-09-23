-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608030003_customer_schedule_history_readability.sql
--
-- Purpose:
--   - separate the historical change made in a revision from the impact
--     of restoring that revision today;
--   - keep the existing history RPC signature and permissions;
--   - preserve the legacy `comparison` response key for older frontends.
--
-- No tables, published revisions, or historical records are rewritten.
-- Requires: 202608030002_customer_schedule_history_management.sql
-- =====================================================================

create or replace function public.get_customer_schedule_history(
  p_customer_id uuid,
  p_selected_version_id uuid default null,
  p_effective_date date default public.current_business_date(),
  p_limit integer default 50
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer record;
  v_current_version_id uuid;
  v_selected_version_id uuid;
  v_open_draft_version_id uuid;
  v_change_base_version_id uuid;
  v_versions jsonb;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_can_restore boolean;
begin
  perform public.require_customer_schedule_history_role();

  select
    c.customer_id,
    c.customer_code,
    c.customer_name,
    c.active
  into v_customer
  from public.customers c
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Customer not found.';
  end if;

  select v.schedule_version_id
  into v_current_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'PUBLISHED'
    and p_effective_date >= v.effective_from
    and (
      v.effective_until is null
      or p_effective_date <= v.effective_until
    )
  order by v.effective_from desc, v.version_number desc
  limit 1;

  select v.schedule_version_id
  into v_open_draft_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'DRAFT'
  order by v.created_at desc
  limit 1;

  if p_selected_version_id is not null then
    select v.schedule_version_id
    into v_selected_version_id
    from public.customer_schedule_versions v
    where v.schedule_version_id = p_selected_version_id
      and v.customer_id = p_customer_id;

    if v_selected_version_id is null then
      raise exception using
        errcode = '22023',
        message = 'The selected schedule revision does not belong to this customer.';
    end if;
  else
    select v.schedule_version_id
    into v_selected_version_id
    from public.customer_schedule_versions v
    where v.customer_id = p_customer_id
    order by
      case when v.schedule_version_id = v_current_version_id then 0 else 1 end,
      v.version_number desc
    limit 1;
  end if;

  if v_selected_version_id is not null then
    select v.based_on_version_id
    into v_change_base_version_id
    from public.customer_schedule_versions v
    where v.schedule_version_id = v_selected_version_id;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'schedule_version_id', history.schedule_version_id,
        'version_number', history.version_number,
        'status', history.status,
        'display_status', history.display_status,
        'is_current', history.schedule_version_id = v_current_version_id,
        'is_selected', history.schedule_version_id = v_selected_version_id,
        'effective_from', history.effective_from,
        'effective_until', history.effective_until,
        'source_code', history.source_code,
        'change_reason', history.change_reason,
        'general_instructions', history.general_instructions,
        'based_on_version_id', history.based_on_version_id,
        'restored_from_version_id', history.restored_from_version_id,
        'created_at', history.created_at,
        'updated_at', history.updated_at,
        'published_at', history.published_at,
        'cancelled_at', history.cancelled_at,
        'changed_by_name', history.changed_by_name,
        'day_count', history.day_count,
        'product_count', history.product_count,
        'trolley_requirement_count', history.trolley_requirement_count,
        'trolley_quantity', history.trolley_quantity
      )
      order by history.version_number desc
    ),
    '[]'::jsonb
  )
  into v_versions
  from (
    select
      v.schedule_version_id,
      v.version_number,
      v.status,
      case
        when v.schedule_version_id = v_current_version_id then 'CURRENT'
        when v.status = 'SUPERSEDED' then 'PREVIOUS'
        when v.status = 'DRAFT' then 'PENDING'
        when v.status = 'CANCELLED' then 'DISCARDED'
        else v.status
      end as display_status,
      v.effective_from,
      v.effective_until,
      v.source_code,
      v.change_reason,
      v.general_instructions,
      v.based_on_version_id,
      v.restored_from_version_id,
      v.created_at,
      v.updated_at,
      v.published_at,
      v.cancelled_at,
      coalesce(
        published_staff.display_name,
        cancelled_staff.display_name,
        updated_staff.display_name,
        created_staff.display_name,
        'System'
      ) as changed_by_name,
      coalesce(counts.day_count, 0) as day_count,
      coalesce(counts.product_count, 0) as product_count,
      coalesce(counts.trolley_requirement_count, 0) as trolley_requirement_count,
      coalesce(counts.trolley_quantity, 0) as trolley_quantity
    from public.customer_schedule_versions v
    left join public.staff_members created_staff
      on created_staff.auth_user_id = v.created_by
    left join public.staff_members updated_staff
      on updated_staff.auth_user_id = v.updated_by
    left join public.staff_members published_staff
      on published_staff.auth_user_id = v.published_by
    left join public.staff_members cancelled_staff
      on cancelled_staff.auth_user_id = v.cancelled_by
    left join lateral (
      select
        (
          select count(*)::integer
          from public.customer_schedule_days d
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as day_count,
        (
          select count(*)::integer
          from public.customer_schedule_products p
          join public.customer_schedule_days d
            on d.schedule_day_id = p.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as product_count,
        (
          select count(*)::integer
          from public.customer_schedule_trolley_requirements req
          join public.customer_schedule_days d
            on d.schedule_day_id = req.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as trolley_requirement_count,
        (
          select coalesce(sum(req.quantity), 0)::integer
          from public.customer_schedule_trolley_requirements req
          join public.customer_schedule_days d
            on d.schedule_day_id = req.schedule_day_id
          where d.schedule_version_id = v.schedule_version_id
            and d.active = true
        ) as trolley_quantity
    ) counts on true
    where v.customer_id = p_customer_id
    order by v.version_number desc
    limit v_limit
  ) history;

  v_can_restore := v_customer.active
    and v_open_draft_version_id is null
    and public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']);

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'effective_date', p_effective_date,
    'customer', jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'active', v_customer.active
    ),
    'permissions', jsonb_build_object(
      'can_view_history', true,
      'can_restore_version', v_can_restore
    ),
    'open_working_revision_id', v_open_draft_version_id,
    'current_version_id', v_current_version_id,
    'selected_version_id', v_selected_version_id,
    'versions', v_versions,
    'current_schedule', case
      when v_current_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_current_version_id
      )
    end,
    'selected_schedule', case
      when v_selected_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_selected_version_id
      )
    end,
    'change_base_version_id', v_change_base_version_id,
    'change_comparison', case
      when v_selected_version_id is null then null
      else public.build_customer_schedule_version_comparison(
        v_change_base_version_id,
        v_selected_version_id
      )
    end,
    'restore_comparison', case
      when v_selected_version_id is null
        or v_selected_version_id = v_current_version_id then null
      else public.build_customer_schedule_version_comparison(
        v_current_version_id,
        v_selected_version_id
      )
    end,
    -- Backward-compatible alias used by older frontend packages.
    'comparison', case
      when v_selected_version_id is null
        or v_selected_version_id = v_current_version_id then null
      else public.build_customer_schedule_version_comparison(
        v_current_version_id,
        v_selected_version_id
      )
    end
  );
end;
$$;


comment on function public.get_customer_schedule_history(uuid, uuid, date, integer)
is 'Returns schedule history with change_comparison (base revision to selected revision) and restore_comparison (current revision to selected revision).';
