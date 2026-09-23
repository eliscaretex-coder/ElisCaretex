-- =====================================================================
-- Laundry Platform V2
-- Migration: 202608030002_customer_schedule_history_management.sql
-- Purpose:
--   Expose protected Customer Schedule history, compare any two revisions,
--   and prepare a historical restore that is reviewed against the current
--   published schedule before publication.
--
-- Safety principles:
--   - Historical and published revisions remain immutable.
--   - History is read through SECURITY DEFINER RPCs only.
--   - Restore creates a new DRAFT revision; it never rewrites old rows.
--   - Restored content is compared with the schedule currently effective
--     on the requested date, so the confirmation screen is meaningful.
-- =====================================================================

begin;

-- Preserve explicit restore lineage separately from the revision used as the
-- comparison base. This lets a restored revision copy Version A while showing
-- its change review against the currently published Version B.
alter table public.customer_schedule_versions
  add column if not exists restored_from_version_id uuid
    references public.customer_schedule_versions(schedule_version_id)
    on delete restrict;

create index if not exists customer_schedule_versions_restored_from_idx
  on public.customer_schedule_versions (restored_from_version_id)
  where restored_from_version_id is not null;

-- ---------------------------------------------------------------------
-- History permission guard
-- ---------------------------------------------------------------------

create or replace function public.require_customer_schedule_history_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Customer Schedule history.';
  end if;
end;
$$;

revoke all on function public.require_customer_schedule_history_role()
from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Generic comparison between two immutable/full revisions
-- ---------------------------------------------------------------------

create or replace function public.build_customer_schedule_version_comparison(
  p_before_version_id uuid,
  p_after_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before_customer_id uuid;
  v_after_customer_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_before_day jsonb;
  v_after_day jsonb;
  v_changed_weekdays jsonb := '[]'::jsonb;
  v_weekday integer;
  v_before_day_count integer;
  v_after_day_count integer;
  v_before_product_count integer;
  v_after_product_count integer;
  v_before_trolley_count integer;
  v_after_trolley_count integer;
  v_before_trolley_quantity integer;
  v_after_trolley_quantity integer;
begin
  if p_before_version_id is not null then
    select customer_id
    into v_before_customer_id
    from public.customer_schedule_versions
    where schedule_version_id = p_before_version_id;

    if v_before_customer_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'The comparison base schedule revision was not found.';
    end if;
  end if;

  if p_after_version_id is not null then
    select customer_id
    into v_after_customer_id
    from public.customer_schedule_versions
    where schedule_version_id = p_after_version_id;

    if v_after_customer_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'The selected schedule revision was not found.';
    end if;
  end if;

  if v_before_customer_id is not null
     and v_after_customer_id is not null
     and v_before_customer_id <> v_after_customer_id then
    raise exception using
      errcode = '22023',
      message = 'Only schedule revisions from the same customer can be compared.';
  end if;

  v_before := case
    when p_before_version_id is null then jsonb_build_object(
      'effective_from', null,
      'effective_until', null,
      'general_instructions', null,
      'days', '[]'::jsonb
    )
    else public.build_customer_schedule_comparable_snapshot(
      p_before_version_id
    )
  end;

  v_after := case
    when p_after_version_id is null then jsonb_build_object(
      'effective_from', null,
      'effective_until', null,
      'general_instructions', null,
      'days', '[]'::jsonb
    )
    else public.build_customer_schedule_comparable_snapshot(
      p_after_version_id
    )
  end;

  for v_weekday in 1..7 loop
    select value
    into v_before_day
    from jsonb_array_elements(
      coalesce(v_before -> 'days', '[]'::jsonb)
    )
    where (value ->> 'production_weekday')::integer = v_weekday
    limit 1;

    select value
    into v_after_day
    from jsonb_array_elements(
      coalesce(v_after -> 'days', '[]'::jsonb)
    )
    where (value ->> 'production_weekday')::integer = v_weekday
    limit 1;

    if v_before_day is distinct from v_after_day then
      v_changed_weekdays := v_changed_weekdays || jsonb_build_array(
        jsonb_build_object(
          'weekday', v_weekday,
          'day_name', public.weekday_name(v_weekday::smallint),
          'change_type', case
            when v_before_day is null then 'ADDED'
            when v_after_day is null then 'REMOVED'
            else 'CHANGED'
          end
        )
      );
    end if;

    v_before_day := null;
    v_after_day := null;
  end loop;

  v_before_day_count := jsonb_array_length(
    coalesce(v_before -> 'days', '[]'::jsonb)
  );
  v_after_day_count := jsonb_array_length(
    coalesce(v_after -> 'days', '[]'::jsonb)
  );

  select
    coalesce(sum(jsonb_array_length(
      coalesce(value -> 'products', '[]'::jsonb)
    )), 0)::integer,
    coalesce(sum(jsonb_array_length(
      coalesce(value -> 'trolley_requirements', '[]'::jsonb)
    )), 0)::integer
  into v_before_product_count, v_before_trolley_count
  from jsonb_array_elements(
    coalesce(v_before -> 'days', '[]'::jsonb)
  );

  select
    coalesce(sum(jsonb_array_length(
      coalesce(value -> 'products', '[]'::jsonb)
    )), 0)::integer,
    coalesce(sum(jsonb_array_length(
      coalesce(value -> 'trolley_requirements', '[]'::jsonb)
    )), 0)::integer
  into v_after_product_count, v_after_trolley_count
  from jsonb_array_elements(
    coalesce(v_after -> 'days', '[]'::jsonb)
  );

  select coalesce(sum((requirement ->> 'quantity')::integer), 0)::integer
  into v_before_trolley_quantity
  from jsonb_array_elements(
    coalesce(v_before -> 'days', '[]'::jsonb)
  ) as before_days(day_row)
  cross join lateral jsonb_array_elements(
    coalesce(day_row -> 'trolley_requirements', '[]'::jsonb)
  ) as before_requirements(requirement);

  select coalesce(sum((requirement ->> 'quantity')::integer), 0)::integer
  into v_after_trolley_quantity
  from jsonb_array_elements(
    coalesce(v_after -> 'days', '[]'::jsonb)
  ) as after_days(day_row)
  cross join lateral jsonb_array_elements(
    coalesce(day_row -> 'trolley_requirements', '[]'::jsonb)
  ) as after_requirements(requirement);

  return jsonb_build_object(
    'before_version_id', p_before_version_id,
    'after_version_id', p_after_version_id,
    'has_changes', v_before is distinct from v_after,
    'effective_period_changed',
      (v_before -> 'effective_from') is distinct from
        (v_after -> 'effective_from')
      or (v_before -> 'effective_until') is distinct from
        (v_after -> 'effective_until'),
    'general_instructions_changed',
      (v_before -> 'general_instructions') is distinct from
        (v_after -> 'general_instructions'),
    'changed_weekdays', v_changed_weekdays,
    'summary', jsonb_build_object(
      'before', jsonb_build_object(
        'days', v_before_day_count,
        'products', v_before_product_count,
        'trolley_requirements', v_before_trolley_count,
        'trolley_quantity', v_before_trolley_quantity
      ),
      'after', jsonb_build_object(
        'days', v_after_day_count,
        'products', v_after_product_count,
        'trolley_requirements', v_after_trolley_count,
        'trolley_quantity', v_after_trolley_quantity
      )
    ),
    'before', v_before,
    'after', v_after
  );
end;
$$;

revoke all on function public.build_customer_schedule_version_comparison(uuid, uuid)
from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Frontend history read model
-- ---------------------------------------------------------------------

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

-- ---------------------------------------------------------------------
-- Restore wrapper: copy historical content, compare against current
-- ---------------------------------------------------------------------

create or replace function public.restore_customer_schedule_management_draft(
  p_source_version_id uuid,
  p_effective_from date,
  p_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_source record;
  v_current_version_id uuid;
  v_schedule_version_id uuid;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A restore reason is required.';
  end if;

  if p_effective_from < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'A restored schedule cannot start before the current business date.';
  end if;

  select
    v.customer_id,
    v.version_number,
    v.status
  into v_source
  from public.customer_schedule_versions v
  where v.schedule_version_id = p_source_version_id
    and v.status in ('PUBLISHED', 'SUPERSEDED', 'CANCELLED');

  if not found then
    raise exception using
      errcode = '22023',
      message = 'The selected historical schedule revision cannot be restored.';
  end if;

  select v.schedule_version_id
  into v_current_version_id
  from public.customer_schedule_versions v
  where v.customer_id = v_source.customer_id
    and v.status = 'PUBLISHED'
    and p_effective_from >= v.effective_from
    and (
      v.effective_until is null
      or p_effective_from <= v.effective_until
    )
  order by v.effective_from desc, v.version_number desc
  limit 1;

  v_schedule_version_id := public.restore_customer_schedule_version(
    p_source_version_id,
    p_effective_from,
    trim(p_reason),
    p_source_application
  );

  update public.customer_schedule_versions
  set
    based_on_version_id = v_current_version_id,
    restored_from_version_id = p_source_version_id,
    change_reason = concat(
      'Restored from Revision ',
      v_source.version_number,
      '. ',
      trim(p_reason)
    ),
    updated_at = now(),
    updated_by = auth.uid(),
    row_version = row_version + 1
  where schedule_version_id = v_schedule_version_id;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'RESTORE_CUSTOMER_SCHEDULE_AS_NEW_REVISION',
    'customer_schedule_versions',
    v_schedule_version_id::text,
    jsonb_build_object(
      'current_version_id', v_current_version_id
    ),
    jsonb_build_object(
      'restored_from_version_id', p_source_version_id,
      'new_schedule_version_id', v_schedule_version_id,
      'effective_from', p_effective_from
    ),
    trim(p_reason),
    p_source_application
  );

  return jsonb_build_object(
    'schedule_version_id', v_schedule_version_id,
    'restored_from_version_id', p_source_version_id,
    'comparison_base_version_id', v_current_version_id,
    'draft', public.build_customer_schedule_version_snapshot(
      v_schedule_version_id
    ),
    'comparison', public.build_customer_schedule_version_comparison(
      v_current_version_id,
      v_schedule_version_id
    )
  );
end;
$$;


-- ---------------------------------------------------------------------
-- One-click protected restore and publication
-- ---------------------------------------------------------------------

create or replace function public.restore_customer_schedule_version_as_update(
  p_source_version_id uuid,
  p_effective_from date,
  p_reason text,
  p_source_application text default 'CUSTOMER_STUDIO_HISTORY'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_restore jsonb;
  v_publish jsonb;
begin
  perform public.require_customer_schedule_edit_role();

  v_restore := public.restore_customer_schedule_management_draft(
    p_source_version_id,
    p_effective_from,
    p_reason,
    p_source_application
  );

  v_publish := public.publish_customer_schedule_draft_with_order_normalization(
    (v_restore ->> 'schedule_version_id')::uuid,
    (v_restore -> 'draft' ->> 'row_version')::integer,
    trim(p_reason),
    p_source_application
  );

  return jsonb_build_object(
    'restored_from_version_id', p_source_version_id,
    'comparison', v_restore -> 'comparison',
    'published_schedule', v_publish -> 'published_schedule',
    'publication_comparison', v_publish -> 'comparison'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Browser privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_customer_schedule_history(uuid, uuid, date, integer)
from public, anon, authenticated;
revoke all on function public.restore_customer_schedule_management_draft(uuid, date, text, text)
from public, anon, authenticated;
revoke all on function public.restore_customer_schedule_version_as_update(uuid, date, text, text)
from public, anon, authenticated;

grant execute on function public.get_customer_schedule_history(uuid, uuid, date, integer)
to authenticated;
grant execute on function public.restore_customer_schedule_version_as_update(uuid, date, text, text)
to authenticated;

comment on column public.customer_schedule_versions.restored_from_version_id
is 'Historical revision copied into a new protected working revision. Separate from based_on_version_id, which is the comparison/publication base.';

comment on function public.get_customer_schedule_history(uuid, uuid, date, integer)
is 'Returns protected Customer Schedule revision metadata, selected revision content and comparison with the currently effective published revision.';

comment on function public.restore_customer_schedule_management_draft(uuid, date, text, text)
is 'Internal protected restore step. Copies historical content into a new DRAFT and compares it against the published schedule effective on the requested date.';

comment on function public.restore_customer_schedule_version_as_update(uuid, date, text, text)
is 'Atomically restores historical content as a new published revision. It never updates or deletes historical revision rows.';

commit;
